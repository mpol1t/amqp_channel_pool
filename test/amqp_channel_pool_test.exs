defmodule AMQPChannelPool.TestWorker do
  @behaviour NimblePool

  @impl true
  def init_pool(opts) do
    {:ok, opts}
  end

  @impl true
  def init_worker(pool_state) do
    connection_opts = Keyword.fetch!(pool_state, :connection)
    label = Keyword.fetch!(connection_opts, :label)

    {:ok, %{channel: {:fake_channel, label}}, pool_state}
  end

  @impl true
  def handle_checkout(_command, _from, worker_state, pool_state) do
    {:ok, worker_state, worker_state, pool_state}
  end

  @impl true
  def handle_checkin(_client_state, _from, worker_state, pool_state) do
    {:ok, worker_state, pool_state}
  end

  @impl true
  def terminate_worker(_reason, _worker_state, pool_state) do
    {:ok, pool_state}
  end
end

defmodule AMQPChannelPool.PoolErrorWorker do
  @behaviour NimblePool

  alias AMQPChannelPool.Worker.RecoveryError

  @impl true
  def init_pool(opts) do
    {:ok, opts}
  end

  @impl true
  def init_worker(pool_state) do
    {:ok, %{channel: :fake_channel, lifecycle: :ready, metadata: %{}}, pool_state}
  end

  @impl true
  def handle_checkout(_command, _from, worker_state, pool_state) do
    error = %RecoveryError{
      stage: :channel_setup,
      reason: :setup_failed_during_recovery,
      worker_lifecycle: :stale
    }

    {:ok, {:pool_error, error}, worker_state, pool_state}
  end

  @impl true
  def handle_checkin(_client_state, _from, worker_state, pool_state) do
    {:ok, worker_state, pool_state}
  end

  @impl true
  def terminate_worker(_reason, _worker_state, pool_state) do
    {:ok, pool_state}
  end
end

defmodule AMQPChannelPool.BorrowerFailureWorker do
  @behaviour NimblePool

  @impl true
  def init_pool(opts) do
    {:ok, opts}
  end

  @impl true
  def init_worker(pool_state) do
    worker_id = System.unique_integer([:positive])
    {:ok, %{channel: {:borrower_channel, worker_id}}, pool_state}
  end

  @impl true
  def handle_checkout(_command, _from, worker_state, pool_state) do
    {:ok, worker_state, worker_state, pool_state}
  end

  @impl true
  def handle_checkin(_client_state, _from, worker_state, pool_state) do
    {:ok, worker_state, pool_state}
  end

  @impl true
  def terminate_worker(_reason, _worker_state, pool_state) do
    {:ok, pool_state}
  end
end

defmodule AMQPChannelPoolTest do
  use ExUnit.Case, async: false

  setup do
    original_worker_module = Application.get_env(:amqp_channel_pool, :worker_module)
    Application.put_env(:amqp_channel_pool, :worker_module, AMQPChannelPool.TestWorker)

    on_exit(fn ->
      if original_worker_module do
        Application.put_env(:amqp_channel_pool, :worker_module, original_worker_module)
      else
        Application.delete_env(:amqp_channel_pool, :worker_module)
      end
    end)

    :ok
  end

  test "start_link returns a clear error when :name is missing" do
    assert {:error, %ArgumentError{message: "missing required :name option"}} =
             AMQPChannelPool.start_link(connection: [label: :pool])
  end

  test "start_link returns a clear error when :connection is missing" do
    assert {:error, %ArgumentError{message: "missing required :connection option"}} =
             AMQPChannelPool.start_link(name: pool_name(:missing_connection))
  end

  test "start_link rejects the legacy :opts key" do
    assert {:error, %ArgumentError{message: "unknown option :opts, use :connection instead"}} =
             AMQPChannelPool.start_link(name: pool_name(:legacy_opts), opts: [label: :pool])
  end

  test "start_link rejects an invalid :channel_setup value" do
    assert {:error,
            %ArgumentError{
              message: "expected :channel_setup to be a function with arity 1, got: :invalid"
            }} =
             AMQPChannelPool.start_link(
               name: pool_name(:invalid_channel_setup),
               connection: [label: :pool],
               channel_setup: :invalid
             )
  end

  test "child_spec uses a stable default id and supports explicit id override" do
    name = pool_name(:child_spec)

    assert %{id: {AMQPChannelPool, ^name}} =
             AMQPChannelPool.child_spec(name: name, connection: [label: :pool])

    assert %{id: :custom_child_id} =
             AMQPChannelPool.child_spec(
               id: :custom_child_id,
               name: name,
               connection: [label: :pool]
             )
  end

  test "child_spec raises before startup on invalid config" do
    assert_raise ArgumentError, "unknown option :opts, use :connection instead", fn ->
      AMQPChannelPool.child_spec(name: pool_name(:invalid_child_spec), opts: [label: :pool])
    end
  end

  test "starting two named pools in the same supervision tree succeeds" do
    primary = pool_name(:primary)
    secondary = pool_name(:secondary)

    children = [
      {AMQPChannelPool, name: primary, connection: [label: :primary]},
      {AMQPChannelPool, name: secondary, connection: [label: :secondary]}
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    on_exit(fn ->
      if Process.alive?(supervisor) do
        _ = catch_exit(Supervisor.stop(supervisor))
      end
    end)

    assert is_pid(resolve_name(primary))
    assert is_pid(resolve_name(secondary))
  end

  test "checkout targets the requested named pool" do
    primary = pool_name(:checkout_primary)
    secondary = pool_name(:checkout_secondary)

    {:ok, primary_pid} = AMQPChannelPool.start_link(name: primary, connection: [label: :primary])

    {:ok, secondary_pid} =
      AMQPChannelPool.start_link(name: secondary, connection: [label: :secondary])

    on_exit(fn ->
      stop_pool(primary_pid, primary)
      stop_pool(secondary_pid, secondary)
    end)

    assert {:ok, {:fake_channel, :primary}} =
             AMQPChannelPool.checkout(primary, fn channel -> channel end, timeout: 100)

    assert {:fake_channel, :secondary} =
             AMQPChannelPool.checkout!(secondary, fn channel -> channel end, timeout: 100)
  end

  test "stop/1 stops only the targeted named pool" do
    primary = pool_name(:stop_primary)
    secondary = pool_name(:stop_secondary)

    {:ok, _primary_pid} = AMQPChannelPool.start_link(name: primary, connection: [label: :primary])

    {:ok, _secondary_pid} =
      AMQPChannelPool.start_link(name: secondary, connection: [label: :secondary])

    assert is_pid(resolve_name(primary))
    assert is_pid(resolve_name(secondary))

    assert :ok = AMQPChannelPool.stop(primary)

    refute is_pid(resolve_name(primary))
    assert is_pid(resolve_name(secondary))

    assert :ok = AMQPChannelPool.stop(secondary)
  end

  test "checkout/3 returns a typed recovery error for pool-layer recovery failure" do
    original_worker_module = Application.get_env(:amqp_channel_pool, :worker_module)
    Application.put_env(:amqp_channel_pool, :worker_module, AMQPChannelPool.PoolErrorWorker)

    on_exit(fn ->
      if original_worker_module do
        Application.put_env(:amqp_channel_pool, :worker_module, original_worker_module)
      else
        Application.delete_env(:amqp_channel_pool, :worker_module)
      end
    end)

    name = pool_name(:pool_error_checkout)

    {:ok, pid} = AMQPChannelPool.start_link(name: name, connection: [label: :pool_error])

    on_exit(fn ->
      stop_pool(pid, name)
    end)

    assert {:error, %AMQPChannelPool.Worker.RecoveryError{} = error} =
             AMQPChannelPool.checkout(name, fn _channel -> :ok end, timeout: 100)

    assert error.stage == :channel_setup
    assert error.reason == :setup_failed_during_recovery
  end

  test "checkout!/3 raises a typed recovery error for pool-layer recovery failure" do
    original_worker_module = Application.get_env(:amqp_channel_pool, :worker_module)
    Application.put_env(:amqp_channel_pool, :worker_module, AMQPChannelPool.PoolErrorWorker)

    on_exit(fn ->
      if original_worker_module do
        Application.put_env(:amqp_channel_pool, :worker_module, original_worker_module)
      else
        Application.delete_env(:amqp_channel_pool, :worker_module)
      end
    end)

    name = pool_name(:pool_error_checkout_bang)

    {:ok, pid} = AMQPChannelPool.start_link(name: name, connection: [label: :pool_error_bang])

    on_exit(fn ->
      stop_pool(pid, name)
    end)

    assert_raise AMQPChannelPool.Worker.RecoveryError, fn ->
      AMQPChannelPool.checkout!(name, fn _channel -> :ok end, timeout: 100)
    end
  end

  test "checkout/3 preserves callback raise semantics" do
    original_worker_module = Application.get_env(:amqp_channel_pool, :worker_module)
    Application.put_env(:amqp_channel_pool, :worker_module, AMQPChannelPool.BorrowerFailureWorker)

    on_exit(fn ->
      if original_worker_module do
        Application.put_env(:amqp_channel_pool, :worker_module, original_worker_module)
      else
        Application.delete_env(:amqp_channel_pool, :worker_module)
      end
    end)

    name = pool_name(:callback_raise)

    {:ok, pid} =
      AMQPChannelPool.start_link(name: name, connection: [label: :callback_raise], pool_size: 1)

    on_exit(fn ->
      stop_pool(pid, name)
    end)

    assert {:ok, {:borrower_channel, initial_worker_id}} =
             AMQPChannelPool.checkout(name, fn channel -> channel end, timeout: 100)

    assert_raise RuntimeError, "callback raised", fn ->
      AMQPChannelPool.checkout(
        name,
        fn _channel ->
          raise "callback raised"
        end,
        timeout: 100
      )
    end

    assert {:ok, {:borrower_channel, replacement_worker_id}} =
             AMQPChannelPool.checkout(name, fn channel -> channel end, timeout: 100)

    assert replacement_worker_id != initial_worker_id
  end

  test "checkout/3 preserves callback exit semantics" do
    original_worker_module = Application.get_env(:amqp_channel_pool, :worker_module)
    Application.put_env(:amqp_channel_pool, :worker_module, AMQPChannelPool.BorrowerFailureWorker)

    on_exit(fn ->
      if original_worker_module do
        Application.put_env(:amqp_channel_pool, :worker_module, original_worker_module)
      else
        Application.delete_env(:amqp_channel_pool, :worker_module)
      end
    end)

    name = pool_name(:callback_exit)

    {:ok, pid} =
      AMQPChannelPool.start_link(name: name, connection: [label: :callback_exit], pool_size: 1)

    on_exit(fn ->
      stop_pool(pid, name)
    end)

    assert {:ok, {:borrower_channel, initial_worker_id}} =
             AMQPChannelPool.checkout(name, fn channel -> channel end, timeout: 100)

    assert catch_exit(
             AMQPChannelPool.checkout(
               name,
               fn _channel ->
                 exit(:callback_exit)
               end,
               timeout: 100
             )
           ) == :callback_exit

    assert {:ok, {:borrower_channel, replacement_worker_id}} =
             AMQPChannelPool.checkout(name, fn channel -> channel end, timeout: 100)

    assert replacement_worker_id != initial_worker_id
  end

  test "checkout/3 preserves callback throw semantics" do
    original_worker_module = Application.get_env(:amqp_channel_pool, :worker_module)
    Application.put_env(:amqp_channel_pool, :worker_module, AMQPChannelPool.BorrowerFailureWorker)

    on_exit(fn ->
      if original_worker_module do
        Application.put_env(:amqp_channel_pool, :worker_module, original_worker_module)
      else
        Application.delete_env(:amqp_channel_pool, :worker_module)
      end
    end)

    name = pool_name(:callback_throw)

    {:ok, pid} =
      AMQPChannelPool.start_link(name: name, connection: [label: :callback_throw], pool_size: 1)

    on_exit(fn ->
      stop_pool(pid, name)
    end)

    assert {:ok, {:borrower_channel, initial_worker_id}} =
             AMQPChannelPool.checkout(name, fn channel -> channel end, timeout: 100)

    assert catch_throw(
             AMQPChannelPool.checkout(
               name,
               fn _channel ->
                 throw(:callback_throw)
               end,
               timeout: 100
             )
           ) == :callback_throw

    assert {:ok, {:borrower_channel, replacement_worker_id}} =
             AMQPChannelPool.checkout(name, fn channel -> channel end, timeout: 100)

    assert replacement_worker_id != initial_worker_id
  end

  defp pool_name(label) do
    {:global, {__MODULE__, label, System.unique_integer([:positive])}}
  end

  defp resolve_name({:global, _} = name) do
    {:global, global_name} = name
    :global.whereis_name(global_name)
  end

  defp stop_pool(pid, name) do
    if Process.alive?(pid) do
      _ = catch_exit(AMQPChannelPool.stop(name))
    end
  end
end
