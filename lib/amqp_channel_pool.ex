defmodule AMQPChannelPool do
  alias AMQPChannelPool.Telemetry

  @default_pool_size 10
  @default_checkout_timeout 5_000
  @valid_start_keys [:id, :name, :connection, :pool_size, :channel_setup]
  @valid_checkout_keys [:timeout]

  @moduledoc """
  Named AMQP channel pools backed by NimblePool.

  A pool must be started with an explicit `:name` and `:connection` options.
  The pool name is then used for `checkout/3`, `checkout!/3`, and `stop/1`.
  The legacy `:opts` startup key is rejected.

  ## Start options

  - `:name` - required pool name
  - `:connection` - required keyword list passed to `AMQP.Connection.open/1`
  - `:pool_size` - optional positive integer worker count, defaults to `#{@default_pool_size}`
  - `:channel_setup` - optional callback invoked with the opened channel; it must return `:ok` or `{:error, reason}`
  - `:id` - optional child specification id override used by `child_spec/1`

  ## Checkout options

  - `:timeout` - optional checkout timeout in milliseconds, defaults to `#{@default_checkout_timeout}`

  ## Borrower failure semantics

  `checkout/3` and `checkout!/3` preserve normal Elixir failure behavior from the
  callback:

  - `raise` re-raises to the caller
  - `exit` exits the caller
  - `throw` throws to the caller

  When any of those abnormal outcomes occur, the borrowed worker is discarded by
  the pool and replaced before reuse. This favors safety over channel reuse.

  Borrowers are responsible for channel hygiene on successful callbacks. If callback
  code leaves channel state uncertain, treat that as a failure so the worker is
  replaced.

  ## Telemetry

  Events are emitted under the `[:amqp_channel_pool, ...]` namespace.

  Event families:

  - `[:amqp_channel_pool, :checkout, :start | :stop | :exception]`
  - `[:amqp_channel_pool, :worker, :init, :start | :stop | :exception]`
  - `[:amqp_channel_pool, :worker, :recover, :start | :stop | :exception]`
  - `[:amqp_channel_pool, :worker, :discard]`
  - `[:amqp_channel_pool, :worker, :terminate]`

  Measurements:

  - `system_time` for start events
  - `duration` for stop and exception events

  Stable metadata keys:

  - `pool`
  - `worker_pid`
  - `worker_state`
  - `recovery_kind`
  - `reason`
  - `timeout`
  - `result`

  ## Responsibility boundary

  This library owns channel-pool lifecycle concerns (startup, checkout, stale detection,
  recovery, and worker replacement). Application services own publisher concerns such
  as routing policy, serialization, retries, idempotency, and confirm waiting logic.

  `:channel_setup` may enable confirm mode or declare topology, but confirm mode
  alone is not sufficient to guarantee end-to-end reliable delivery.

  ## Examples

      children = [
        {AMQPChannelPool,
         name: MyApp.PrimaryPool,
         connection: [
           host: "localhost",
           port: 5672,
           username: "guest",
           password: "guest"
         ],
         pool_size: 5,
         channel_setup: &MyApp.AMQPTopology.declare/1}
      ]

      {:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)

      {:ok, :ok} =
        AMQPChannelPool.checkout(MyApp.PrimaryPool, fn channel ->
          AMQP.Queue.declare(channel, "service.health", durable: true)
        end, timeout: 5_000)

      :ok = AMQPChannelPool.stop(MyApp.PrimaryPool)
  """

  @doc """
  Starts a named AMQP channel pool.

  Returns `{:error, %ArgumentError{}}` when startup options are invalid.
  """
  def start_link(opts) do
    with {:ok, config} <- validate_start_opts(opts) do
      nimble_pool_module().start_link(
        worker:
          {worker_module(),
           [
             pool: config.name,
             connection: config.connection,
             channel_setup: config.channel_setup,
             pool_size: config.pool_size
           ]},
        name: config.name,
        pool_size: config.pool_size,
        lazy: false
      )
    end
  end

  @doc """
  Defines the child specification for a named pool.

  The default child id is `{AMQPChannelPool, pool_name}`. Use `:id` to override it.
  Raises `ArgumentError` when startup options are invalid.
  """
  def child_spec(opts) do
    config =
      case validate_start_opts(opts) do
        {:ok, config} -> config
        {:error, exception} -> raise exception
      end

    %{
      id: config.id || child_id(config.name),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Checks out a channel from the named pool and returns `{:ok, result}` on success.

  Returns `{:error, reason}` for pool-layer checkout failures.
  Invalid checkout options return `{:error, %ArgumentError{}}`.
  Callback `raise`/`exit`/`throw` are not converted to `{:error, reason}` and
  propagate with standard Elixir semantics.
  """
  def checkout(pool_name, fun, opts) when is_function(fun, 1) do
    with {:ok, timeout} <- validate_checkout_opts(opts) do
      checkout_pool(pool_name, fun, timeout)
    end
  end

  @doc """
  Checks out a channel from the named pool and returns the callback result.

  Raises for invalid checkout options and pool-layer checkout failures.
  Callback `raise`/`exit`/`throw` propagate directly.
  """
  def checkout!(pool_name, fun, opts) when is_function(fun, 1) do
    timeout =
      case validate_checkout_opts(opts) do
        {:ok, timeout} -> timeout
        {:error, exception} -> raise exception
      end

    case checkout_pool(pool_name, fun, timeout) do
      {:ok, result} ->
        result

      {:error, error} ->
        raise error
    end
  end

  @doc """
  Stops the named pool.
  """
  def stop(pool_name) do
    GenServer.stop(pool_name)
  end

  defp checkout_pool(pool_name, fun, timeout) do
    nimble_pool = nimble_pool_module()
    started_at = System.monotonic_time()
    exception_marker_key = {__MODULE__, :checkout_exception_emitted}
    previous_exception_marker = Process.get(exception_marker_key)
    Process.delete(exception_marker_key)

    Telemetry.emit_checkout_start(%{pool: pool_name, timeout: timeout})

    try do
      {:checkout_result, result, worker_context} =
        nimble_pool.checkout!(
          pool_name,
          :checkout,
          fn worker_pid, client_state ->
            worker_context = %{
              worker_pid: normalize_worker_pid(worker_pid),
              worker_state: normalize_worker_state(client_state)
            }

            case client_state do
              {:pool_error, error} ->
                {{:checkout_result, {:error, error}, worker_context}, client_state}

              %{channel: channel} = worker_state ->
                callback_metadata = %{
                  pool: pool_name,
                  timeout: timeout,
                  worker_pid: normalize_worker_pid(worker_pid),
                  worker_state: normalize_worker_state(worker_state),
                  result: :callback_exception
                }

                try do
                  {{:checkout_result, {:ok, fun.(channel)}, worker_context}, worker_state}
                rescue
                  exception ->
                    Process.put(exception_marker_key, true)

                    Telemetry.emit_checkout_exception(
                      System.monotonic_time() - started_at,
                      Map.merge(callback_metadata, %{reason: exception, kind: :error})
                    )

                    reraise exception, __STACKTRACE__
                catch
                  kind, reason ->
                    Process.put(exception_marker_key, true)

                    Telemetry.emit_checkout_exception(
                      System.monotonic_time() - started_at,
                      Map.merge(callback_metadata, %{reason: reason, kind: kind})
                    )

                    :erlang.raise(kind, reason, __STACKTRACE__)
                end
            end
          end,
          timeout
        )

      Telemetry.emit_checkout_stop(System.monotonic_time() - started_at, %{
        pool: pool_name,
        timeout: timeout,
        worker_pid: worker_context.worker_pid,
        worker_state: worker_context.worker_state,
        result: checkout_result(result),
        reason: checkout_reason(result)
      })

      result
    catch
      kind, reason ->
        if Process.get(exception_marker_key) != true do
          Telemetry.emit_checkout_exception(System.monotonic_time() - started_at, %{
            pool: pool_name,
            timeout: timeout,
            reason: reason,
            kind: kind,
            result: :pool_checkout_exception
          })
        end

        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if previous_exception_marker == nil do
        Process.delete(exception_marker_key)
      else
        Process.put(exception_marker_key, previous_exception_marker)
      end
    end
  end

  defp checkout_result({:ok, _result}), do: :ok
  defp checkout_result({:error, _reason}), do: :pool_error

  defp checkout_reason({:ok, _result}), do: nil
  defp checkout_reason({:error, reason}), do: reason

  defp normalize_worker_state(%{lifecycle: lifecycle}), do: lifecycle
  defp normalize_worker_state({:pool_error, _error}), do: :pool_error
  defp normalize_worker_state(%{metadata: _} = state), do: Map.keys(state) |> Enum.sort()
  defp normalize_worker_state(%{} = state), do: Map.keys(state) |> Enum.sort()
  defp normalize_worker_state(state), do: state

  defp normalize_worker_pid({pid, _ref}) when is_pid(pid), do: pid
  defp normalize_worker_pid(pid) when is_pid(pid), do: pid
  defp normalize_worker_pid(other), do: other

  defp validate_start_opts(opts) when not is_list(opts) do
    {:error,
     ArgumentError.exception("expected start options to be a keyword list, got: #{inspect(opts)}")}
  end

  defp validate_start_opts(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error,
         ArgumentError.exception(
           "expected start options to be a keyword list, got: #{inspect(opts)}"
         )}

      Keyword.has_key?(opts, :opts) ->
        {:error, ArgumentError.exception("unknown option :opts, use :connection instead")}

      true ->
        validate_known_start_opts(opts)
    end
  end

  defp validate_known_start_opts(opts) do
    unknown_keys = Keyword.keys(opts) -- @valid_start_keys

    if unknown_keys != [] do
      {:error,
       ArgumentError.exception("unknown start option(s): #{inspect(Enum.sort(unknown_keys))}")}
    else
      with {:ok, name} <- validate_pool_name(Keyword.get(opts, :name)),
           {:ok, connection} <- validate_connection(Keyword.get(opts, :connection, :missing)),
           {:ok, channel_setup} <- validate_channel_setup(Keyword.get(opts, :channel_setup)),
           {:ok, pool_size} <-
             validate_pool_size(Keyword.get(opts, :pool_size, @default_pool_size)) do
        {:ok,
         %{
           id: Keyword.get(opts, :id),
           name: name,
           connection: connection,
           channel_setup: channel_setup,
           pool_size: pool_size
         }}
      end
    end
  end

  defp validate_checkout_opts(opts) when not is_list(opts) do
    {:error,
     ArgumentError.exception(
       "expected checkout options to be a keyword list, got: #{inspect(opts)}"
     )}
  end

  defp validate_checkout_opts(opts) do
    if Keyword.keyword?(opts) do
      validate_known_checkout_opts(opts)
    else
      {:error,
       ArgumentError.exception(
         "expected checkout options to be a keyword list, got: #{inspect(opts)}"
       )}
    end
  end

  defp validate_known_checkout_opts(opts) do
    unknown_keys = Keyword.keys(opts) -- @valid_checkout_keys

    if unknown_keys != [] do
      {:error,
       ArgumentError.exception("unknown checkout option(s): #{inspect(Enum.sort(unknown_keys))}")}
    else
      validate_timeout(Keyword.get(opts, :timeout, @default_checkout_timeout))
    end
  end

  defp validate_pool_name(nil) do
    {:error, ArgumentError.exception("missing required :name option")}
  end

  defp validate_pool_name(name) when is_atom(name), do: {:ok, name}
  defp validate_pool_name({:global, _} = name), do: {:ok, name}
  defp validate_pool_name({:via, _, _} = name), do: {:ok, name}

  defp validate_pool_name(name) do
    {:error,
     ArgumentError.exception(
       "expected :name to be an atom, {:global, term}, or {:via, module, term}, got: #{inspect(name)}"
     )}
  end

  defp validate_connection(:missing) do
    {:error, ArgumentError.exception("missing required :connection option")}
  end

  defp validate_connection(connection) when is_list(connection) do
    if Keyword.keyword?(connection) do
      {:ok, connection}
    else
      {:error,
       ArgumentError.exception(
         "expected :connection to be a keyword list, got: #{inspect(connection)}"
       )}
    end
  end

  defp validate_connection(connection) do
    {:error,
     ArgumentError.exception(
       "expected :connection to be a keyword list, got: #{inspect(connection)}"
     )}
  end

  defp validate_pool_size(pool_size) when is_integer(pool_size) and pool_size > 0,
    do: {:ok, pool_size}

  defp validate_pool_size(pool_size) do
    {:error,
     ArgumentError.exception(
       "expected :pool_size to be a positive integer, got: #{inspect(pool_size)}"
     )}
  end

  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: {:ok, timeout}

  defp validate_timeout(timeout) do
    {:error,
     ArgumentError.exception(
       "expected :timeout to be a non-negative integer, got: #{inspect(timeout)}"
     )}
  end

  defp child_id(name), do: {__MODULE__, name}

  defp validate_channel_setup(nil), do: {:ok, nil}

  defp validate_channel_setup(channel_setup) when is_function(channel_setup, 1),
    do: {:ok, channel_setup}

  defp validate_channel_setup(channel_setup) do
    {:error,
     ArgumentError.exception(
       "expected :channel_setup to be a function with arity 1, got: #{inspect(channel_setup)}"
     )}
  end

  defp nimble_pool_module do
    Application.get_env(:amqp_channel_pool, :nimble_pool_module, NimblePool)
  end

  defp worker_module do
    Application.get_env(:amqp_channel_pool, :worker_module, AMQPChannelPool.Worker)
  end
end
