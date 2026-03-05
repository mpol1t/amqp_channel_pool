defmodule AMQPChannelPool.Worker do
  @moduledoc false
  @behaviour NimblePool

  alias AMQPChannelPool.Telemetry

  require Logger

  defmodule StartupError do
    defexception [:stage, :reason]

    @impl true
    def message(%__MODULE__{stage: stage, reason: reason}) do
      "worker startup failed during #{inspect(stage)}: #{inspect(reason)}"
    end
  end

  defmodule RecoveryError do
    defexception [:stage, :reason, :worker_lifecycle]

    @impl true
    def message(%__MODULE__{stage: stage, reason: reason, worker_lifecycle: lifecycle}) do
      "worker recovery failed during #{inspect(stage)} from lifecycle #{inspect(lifecycle)}: #{inspect(reason)}"
    end
  end

  defmodule State do
    @enforce_keys [:lifecycle, :started_at]
    defstruct lifecycle: :starting,
              connection: nil,
              channel: nil,
              connection_monitor_ref: nil,
              channel_monitor_ref: nil,
              started_at: nil,
              ready_at: nil,
              metadata: %{}

    @type lifecycle :: :starting | :ready | :stale | :recovering | :closing

    @type t :: %__MODULE__{
            lifecycle: lifecycle(),
            connection: term() | nil,
            channel: term() | nil,
            connection_monitor_ref: reference() | nil,
            channel_monitor_ref: reference() | nil,
            started_at: integer(),
            ready_at: integer() | nil,
            metadata: map()
          }
  end

  @valid_transitions %{
    starting: [:ready, :closing],
    ready: [:stale, :closing],
    stale: [:recovering, :closing],
    recovering: [:ready, :stale, :closing],
    closing: []
  }

  @impl true
  @doc false
  def init_pool(opts) do
    pool_config = %{
      pool: Keyword.get(opts, :pool),
      connection: Keyword.fetch!(opts, :connection),
      channel_setup: Keyword.get(opts, :channel_setup)
    }

    pool_size = Keyword.fetch!(opts, :pool_size)

    case build_initial_workers(pool_size, pool_config) do
      {:ok, workers} ->
        {:ok, %{config: pool_config, initial_workers: :queue.from_list(workers)}}

      {:error, stage, reason, workers_to_cleanup} ->
        Enum.each(workers_to_cleanup, &cleanup_startup_failure/1)
        {:stop, %StartupError{stage: stage, reason: reason}}
    end
  end

  @impl true
  @doc false
  def init_worker(pool_state) do
    Logger.debug("AMQPChannelPool.Worker starting...")

    case take_initial_worker(pool_state) do
      {:ok, worker_state, next_pool_state} ->
        {:ok, worker_state, next_pool_state}

      :empty ->
        case build_worker_state(pool_state.config) do
          {:ok, worker_state} ->
            {:ok, worker_state, pool_state}

          {:error, stage, reason, worker_state} ->
            cleanup_startup_failure(worker_state)
            raise StartupError, stage: stage, reason: reason
        end
    end
  end

  defp take_initial_worker(%{initial_workers: queue} = pool_state) do
    case :queue.out(queue) do
      {{:value, worker_state}, remaining_queue} ->
        {:ok, worker_state, %{pool_state | initial_workers: remaining_queue}}

      {:empty, _queue} ->
        :empty
    end
  end

  defp build_initial_workers(pool_size, pool_config) do
    Enum.reduce_while(1..pool_size, {:ok, []}, fn _index, {:ok, workers} ->
      case build_worker_state(pool_config) do
        {:ok, worker_state} ->
          {:cont, {:ok, [worker_state | workers]}}

        {:error, stage, reason, worker_state} ->
          workers_to_cleanup = [worker_state | workers]
          {:halt, {:error, stage, reason, workers_to_cleanup}}
      end
    end)
    |> case do
      {:ok, workers} -> {:ok, Enum.reverse(workers)}
      {:error, stage, reason, workers} -> {:error, stage, reason, workers}
    end
  end

  @impl true
  @doc false
  def handle_checkout(_command, _from, worker_state, pool_state) do
    case prepare_worker_for_checkout(worker_state, pool_state.config) do
      {:ok, ready_worker_state} ->
        {:ok, ready_worker_state, ready_worker_state, pool_state}

      {:error, %RecoveryError{} = error, failed_worker_state} ->
        worker_state_for_removal =
          failed_worker_state
          |> transition_to_closing()
          |> put_metadata(:discard_reason, error)

        {:ok, {:pool_error, error}, worker_state_for_removal, pool_state}
    end
  end

  @impl true
  @doc false
  def handle_checkin(_client_state, _from, worker_state, pool_state) do
    case worker_state.lifecycle do
      :ready ->
        {:ok, worker_state, pool_state}

      :closing ->
        discard_reason = Map.get(worker_state.metadata, :discard_reason)

        Telemetry.emit_worker_discard(%{
          pool: pool_state.config.pool,
          worker_pid: self(),
          worker_state: worker_state.lifecycle,
          recovery_kind: Map.get(worker_state.metadata, :recovery_from_lifecycle),
          reason: discard_reason,
          result: :discarded
        })

        {:remove, {:discard_worker, discard_reason}, pool_state}

      _ ->
        Telemetry.emit_worker_discard(%{
          pool: pool_state.config.pool,
          worker_pid: self(),
          worker_state: worker_state.lifecycle,
          reason: {:invalid_lifecycle, worker_state.lifecycle},
          result: :discarded
        })

        {:remove, {:discard_invalid_lifecycle, worker_state.lifecycle}, pool_state}
    end
  end

  @impl true
  @doc false
  def handle_info({:DOWN, ref, :process, _pid, reason}, worker_state) do
    connection_ref = worker_state.connection_monitor_ref
    channel_ref = worker_state.channel_monitor_ref

    updated_state =
      case ref do
        ^connection_ref ->
          mark_stale(worker_state, {:connection_down, reason})

        ^channel_ref ->
          mark_stale(worker_state, {:channel_down, reason})

        _ ->
          worker_state
      end

    {:ok, updated_state}
  end

  @impl true
  @doc false
  def handle_info(_message, worker_state) do
    {:ok, worker_state}
  end

  @impl true
  @doc false
  def terminate_worker(reason, worker_state, pool_state) do
    Logger.debug("AMQPChannelPool.Worker terminating...")
    terminate_reason = Map.get(worker_state.metadata, :discard_reason) || reason

    Telemetry.emit_worker_terminate(%{
      pool: pool_state.config.pool,
      worker_pid: self(),
      worker_state: worker_state.lifecycle,
      recovery_kind: Map.get(worker_state.metadata, :recovery_from_lifecycle),
      reason: terminate_reason,
      result: :terminated
    })

    worker_state
    |> transition_to_closing()
    |> cleanup_runtime_resources()

    {:ok, pool_state}
  end

  defp build_worker_state(pool_config) do
    started_at = System.monotonic_time()
    state = %State{lifecycle: :starting, started_at: System.monotonic_time()}

    Telemetry.emit_worker_init_start(%{
      pool: pool_config.pool,
      worker_pid: self(),
      worker_state: state.lifecycle
    })

    case initialize_worker(pool_config, state) do
      {:ok, ready_state} ->
        Telemetry.emit_worker_init_stop(System.monotonic_time() - started_at, %{
          pool: pool_config.pool,
          worker_pid: self(),
          worker_state: ready_state.lifecycle,
          result: :ok
        })

        {:ok, ready_state}

      {:error, stage, reason, failed_state} = error ->
        Telemetry.emit_worker_init_exception(System.monotonic_time() - started_at, %{
          pool: pool_config.pool,
          worker_pid: self(),
          worker_state: failed_state.lifecycle,
          reason: {stage, reason},
          result: :error
        })

        error
    end
  end

  defp prepare_worker_for_checkout(%State{} = worker_state, pool_config) do
    cond do
      worker_state.lifecycle == :ready and resources_alive?(worker_state) ->
        {:ok, worker_state}

      worker_state.lifecycle == :ready ->
        worker_state
        |> mark_stale({:checkout_validation_failed, :resource_not_alive})
        |> recover_worker(pool_config)

      worker_state.lifecycle == :stale ->
        recover_worker(worker_state, pool_config)

      true ->
        {:error,
         %RecoveryError{
           stage: :checkout_validation,
           reason: {:unexpected_lifecycle, worker_state.lifecycle},
           worker_lifecycle: worker_state.lifecycle
         }, worker_state}
    end
  end

  defp recover_worker(%State{} = worker_state, pool_config) do
    started_at = System.monotonic_time()
    recovering_state = transition!(worker_state, :recovering)

    Telemetry.emit_worker_recover_start(%{
      pool: pool_config.pool,
      worker_pid: self(),
      worker_state: recovering_state.lifecycle,
      recovery_kind: worker_state.lifecycle
    })

    cleanup_runtime_resources(recovering_state)
    recovery_base_state = reset_resources(recovering_state)

    case initialize_worker(pool_config, recovery_base_state) do
      {:ok, recovered_state} ->
        Telemetry.emit_worker_recover_stop(System.monotonic_time() - started_at, %{
          pool: pool_config.pool,
          worker_pid: self(),
          worker_state: recovered_state.lifecycle,
          recovery_kind: worker_state.lifecycle,
          result: :ok
        })

        {:ok,
         recovered_state
         |> put_metadata(:recovered_at, System.monotonic_time())
         |> put_metadata(:recovery_from_lifecycle, worker_state.lifecycle)}

      {:error, stage, reason, failed_state} ->
        Telemetry.emit_worker_recover_exception(System.monotonic_time() - started_at, %{
          pool: pool_config.pool,
          worker_pid: self(),
          worker_state: failed_state.lifecycle,
          recovery_kind: worker_state.lifecycle,
          reason: {stage, reason},
          result: :error
        })

        cleanup_startup_failure(failed_state)

        {:error,
         %RecoveryError{
           stage: stage,
           reason: reason,
           worker_lifecycle: worker_state.lifecycle
         }, failed_state}
    end
  end

  defp reset_resources(state) do
    %State{
      state
      | connection: nil,
        channel: nil,
        connection_monitor_ref: nil,
        channel_monitor_ref: nil
    }
  end

  defp initialize_worker(pool_config, state) do
    connection_opts = pool_config.connection
    channel_setup = pool_config.channel_setup
    client = amqp_client_module()

    with {:ok, state} <- open_connection(state, client, connection_opts),
         {:ok, state} <- open_channel(state, client),
         {:ok, state} <- run_channel_setup(state, channel_setup),
         {:ok, state} <- install_monitors(state) do
      {:ok,
       state
       |> transition!(:ready)
       |> put_metadata(:channel_setup?, is_function(channel_setup, 1))
       |> Map.put(:ready_at, System.monotonic_time())}
    else
      {:error, stage, reason, failed_state} ->
        {:error, stage, reason, failed_state}
    end
  end

  defp open_connection(state, client, connection_opts) do
    case client.open_connection(connection_opts) do
      {:ok, connection} -> {:ok, put_connection(state, connection)}
      {:error, reason} -> {:error, :connection_open, reason, state}
    end
  end

  defp open_channel(state, client) do
    case client.open_channel(state.connection) do
      {:ok, channel} -> {:ok, put_channel(state, channel)}
      {:error, reason} -> {:error, :channel_open, reason, state}
    end
  end

  defp run_channel_setup(state, nil), do: {:ok, state}

  defp run_channel_setup(state, channel_setup) do
    case channel_setup.(state.channel) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, :channel_setup, reason, state}
      other -> {:error, :channel_setup, {:invalid_return, other}, state}
    end
  rescue
    exception ->
      {:error, :channel_setup, {:raised, exception, __STACKTRACE__}, state}
  catch
    kind, reason ->
      {:error, :channel_setup, {kind, reason}, state}
  end

  defp install_monitors(state) do
    with {:ok, connection_pid} <- fetch_pid(state.connection, :connection),
         {:ok, channel_pid} <- fetch_pid(state.channel, :channel) do
      {:ok,
       %State{
         state
         | connection_monitor_ref: Process.monitor(connection_pid),
           channel_monitor_ref: Process.monitor(channel_pid)
       }}
    end
  end

  defp fetch_pid(%{pid: pid}, _resource) when is_pid(pid), do: {:ok, pid}

  defp fetch_pid(resource, name),
    do: {:error, :monitor_installation, {:missing_pid, name, resource}}

  defp put_connection(state, connection), do: %State{state | connection: connection}
  defp put_channel(state, channel), do: %State{state | channel: channel}

  defp put_metadata(state, key, value) do
    %State{state | metadata: Map.put(state.metadata, key, value)}
  end

  defp resources_alive?(state) do
    resource_alive?(state.connection, :connection) and resource_alive?(state.channel, :channel)
  end

  defp resource_alive?(resource, name) do
    case fetch_pid(resource, name) do
      {:ok, pid} -> Process.alive?(pid)
      {:error, _, _} -> false
    end
  end

  defp mark_stale(%State{lifecycle: :ready} = state, reason) do
    state
    |> transition!(:stale)
    |> put_metadata(:stale_reason, reason)
  end

  defp mark_stale(%State{lifecycle: :stale} = state, _reason), do: state

  defp mark_stale(state, _reason), do: state

  defp transition!(%State{lifecycle: from} = state, to) do
    if to in Map.fetch!(@valid_transitions, from) do
      %State{state | lifecycle: to}
    else
      raise ArgumentError,
            "invalid worker lifecycle transition from #{inspect(from)} to #{inspect(to)}"
    end
  end

  defp transition_to_closing(%State{lifecycle: :closing} = state), do: state
  defp transition_to_closing(state), do: transition!(state, :closing)

  defp cleanup_startup_failure(state) do
    state
    |> transition_to_closing()
    |> cleanup_runtime_resources()
  end

  defp cleanup_runtime_resources(state) do
    maybe_demonitor(state.connection_monitor_ref)
    maybe_demonitor(state.channel_monitor_ref)
    close_resource(:channel, state.channel)
    close_resource(:connection, state.connection)
    :ok
  end

  defp maybe_demonitor(nil), do: :ok
  defp maybe_demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp close_resource(_kind, nil), do: :ok

  defp close_resource(:channel, channel) do
    client = amqp_client_module()

    try do
      client.close_channel(channel)
      :ok
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp close_resource(:connection, connection) do
    client = amqp_client_module()

    try do
      client.close_connection(connection)
      :ok
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp amqp_client_module do
    Application.get_env(:amqp_channel_pool, :amqp_client_module, AMQPChannelPool.AMQPClient)
  end
end
