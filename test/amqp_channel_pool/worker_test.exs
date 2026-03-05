defmodule AMQPChannelPool.WorkerTest.FakeAMQPClient do
  def open_connection(connection_opts) do
    test_pid = Keyword.fetch!(connection_opts, :test_pid)
    label = Keyword.fetch!(connection_opts, :label)
    connection_open_fun = Keyword.get(connection_opts, :connection_open_fun)
    channel_open_fun = Keyword.get(connection_opts, :channel_open_fun)

    send(test_pid, {:fake_amqp, :open_connection, label})

    open_result =
      if is_function(connection_open_fun, 1) do
        connection_open_fun.({:open_connection, label})
      else
        Keyword.get(connection_opts, :connection_open_result, :ok)
      end

    case open_result do
      :ok ->
        {:ok,
         %{
           pid: spawn_resource(),
           label: label,
           test_pid: test_pid,
           channel_open_fun: channel_open_fun,
           channel_open_result: Keyword.get(connection_opts, :channel_open_result, :ok)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def open_channel(connection) do
    send(connection.test_pid, {:fake_amqp, :open_channel, connection.label})

    open_result =
      if is_function(connection.channel_open_fun, 1) do
        connection.channel_open_fun.({:open_channel, connection.label})
      else
        connection.channel_open_result
      end

    case open_result do
      :ok ->
        {:ok,
         %{
           pid: spawn_resource(),
           label: connection.label,
           test_pid: connection.test_pid
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def close_connection(connection) do
    send(connection.test_pid, {:fake_amqp, :close_connection, connection.label})
    stop_resource(connection.pid)
    :ok
  end

  def close_channel(channel) do
    send(channel.test_pid, {:fake_amqp, :close_channel, channel.label})
    stop_resource(channel.pid)
    :ok
  end

  defp spawn_resource do
    spawn(fn -> wait_for_stop() end)
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end

  defp stop_resource(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end
end

defmodule AMQPChannelPool.WorkerTest do
  use ExUnit.Case, async: false

  alias AMQPChannelPool
  alias AMQPChannelPool.Worker
  alias AMQPChannelPool.Worker.RecoveryError
  alias AMQPChannelPool.Worker.StartupError
  alias AMQPChannelPool.Worker.State

  setup do
    original_amqp_client = Application.get_env(:amqp_channel_pool, :amqp_client_module)

    Application.put_env(
      :amqp_channel_pool,
      :amqp_client_module,
      AMQPChannelPool.WorkerTest.FakeAMQPClient
    )

    on_exit(fn ->
      if original_amqp_client do
        Application.put_env(:amqp_channel_pool, :amqp_client_module, original_amqp_client)
      else
        Application.delete_env(:amqp_channel_pool, :amqp_client_module)
      end
    end)

    :ok
  end

  test "init_worker reaches ready only after connection, channel, setup, and monitor installation" do
    test_pid = self()

    assert {:ok, pool_state} =
             Worker.init_pool(
               connection: [test_pid: test_pid, label: :ready],
               channel_setup: &setup_ready_channel/1,
               pool_size: 1
             )

    assert {:ok, %State{} = worker_state, pool_state} = Worker.init_worker(pool_state)

    assert worker_state.lifecycle == :ready
    assert is_reference(worker_state.connection_monitor_ref)
    assert is_reference(worker_state.channel_monitor_ref)
    assert is_integer(worker_state.started_at)
    assert is_integer(worker_state.ready_at)
    assert worker_state.ready_at >= worker_state.started_at
    assert worker_state.metadata == %{channel_setup?: true}

    assert_received {:fake_amqp, :open_connection, :ready}
    assert_received {:fake_amqp, :open_channel, :ready}
    assert_received {:channel_setup_called, :ready}

    assert {:ok, _pool_state} = Worker.terminate_worker(:shutdown, worker_state, pool_state)
    assert_received {:fake_amqp, :close_channel, :ready}
    assert_received {:fake_amqp, :close_connection, :ready}
  end

  test "init_worker does not invoke setup when no channel_setup is configured" do
    assert {:ok, pool_state} =
             Worker.init_pool(connection: [test_pid: self(), label: :no_setup], pool_size: 1)

    assert {:ok, %State{} = worker_state, pool_state} = Worker.init_worker(pool_state)
    assert worker_state.lifecycle == :ready
    assert worker_state.metadata == %{channel_setup?: false}

    refute_received {:channel_setup_called, :no_setup}

    assert {:ok, _pool_state} = Worker.terminate_worker(:shutdown, worker_state, pool_state)
    assert_received {:fake_amqp, :close_channel, :no_setup}
    assert_received {:fake_amqp, :close_connection, :no_setup}
  end

  test "init_pool closes channel and connection when channel setup fails" do
    assert {:stop, %StartupError{} = error} =
             Worker.init_pool(
               connection: [test_pid: self(), label: :setup_failure],
               channel_setup: fn _channel ->
                 send(self(), {:channel_setup_called, :setup_failure})
                 {:error, :setup_failed}
               end,
               pool_size: 1
             )

    assert error.stage == :channel_setup
    assert error.reason == :setup_failed

    assert_received {:fake_amqp, :open_connection, :setup_failure}
    assert_received {:fake_amqp, :open_channel, :setup_failure}
    assert_received {:channel_setup_called, :setup_failure}
    assert_received {:fake_amqp, :close_channel, :setup_failure}
    assert_received {:fake_amqp, :close_connection, :setup_failure}
  end

  test "init_pool closes connection when channel open fails" do
    assert {:stop, %StartupError{} = error} =
             Worker.init_pool(
               connection: [
                 test_pid: self(),
                 label: :channel_open_failure,
                 channel_open_result: {:error, :cannot_open_channel}
               ],
               pool_size: 1
             )

    assert error.stage == :channel_open
    assert error.reason == :cannot_open_channel

    assert_received {:fake_amqp, :open_connection, :channel_open_failure}
    assert_received {:fake_amqp, :open_channel, :channel_open_failure}
    refute_received {:fake_amqp, :close_channel, :channel_open_failure}
    assert_received {:fake_amqp, :close_connection, :channel_open_failure}
  end

  test "init_pool fails cleanly when connection open fails" do
    assert {:stop, %StartupError{} = error} =
             Worker.init_pool(
               connection: [
                 test_pid: self(),
                 label: :connection_open_failure,
                 connection_open_result: {:error, :cannot_open_connection}
               ],
               pool_size: 1
             )

    assert error.stage == :connection_open
    assert error.reason == :cannot_open_connection

    assert_received {:fake_amqp, :open_connection, :connection_open_failure}
    refute_received {:fake_amqp, :open_channel, :connection_open_failure}
    refute_received {:fake_amqp, :close_channel, :connection_open_failure}
    refute_received {:fake_amqp, :close_connection, :connection_open_failure}
  end

  test "start_link starts a pool only after the worker is ready" do
    test_pid = self()
    name = pool_name(:integration_ready)

    {:ok, pid} =
      AMQPChannelPool.start_link(
        name: name,
        connection: [test_pid: test_pid, label: :integration_ready],
        channel_setup: fn %{label: label} ->
          send(test_pid, {:channel_setup_called, label})
          :ok
        end,
        pool_size: 1
      )

    on_exit(fn ->
      if Process.alive?(pid), do: AMQPChannelPool.stop(name)
    end)

    assert_received {:fake_amqp, :open_connection, :integration_ready}
    assert_received {:fake_amqp, :open_channel, :integration_ready}
    assert_received {:channel_setup_called, :integration_ready}
    assert {:ok, :integration_ready} = AMQPChannelPool.checkout(name, & &1.label, timeout: 100)

    assert :ok = AMQPChannelPool.stop(name)
    refute Process.alive?(pid)
    assert_received {:fake_amqp, :close_channel, :integration_ready}
    assert_received {:fake_amqp, :close_connection, :integration_ready}
  end

  test "start_link fails without registering a pool when channel setup fails" do
    name = pool_name(:integration_setup_failure)
    original_trap_exit = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, original_trap_exit)
    end)

    result =
      AMQPChannelPool.start_link(
        name: name,
        connection: [test_pid: self(), label: :integration_setup_failure],
        channel_setup: fn _channel -> {:error, :setup_failed} end,
        pool_size: 1
      )

    error =
      case result do
        {:error, %StartupError{} = error} ->
          error

        other ->
          flunk("expected start_link/1 to fail with StartupError, got: #{inspect(other)}")
      end

    assert error.stage == :channel_setup
    assert error.reason == :setup_failed
    assert_receive {:fake_amqp, :open_connection, :integration_setup_failure}
    assert_receive {:fake_amqp, :open_channel, :integration_setup_failure}
    assert_receive {:fake_amqp, :close_channel, :integration_setup_failure}
    assert_receive {:fake_amqp, :close_connection, :integration_setup_failure}
    assert resolve_name(name) == :undefined
  end

  test "checkout validation marks dead resources stale and recovers once before checkout" do
    test_pid = self()

    assert {:ok, pool_state} =
             Worker.init_pool(
               connection: [test_pid: test_pid, label: :recover_dead_resource],
               pool_size: 1
             )

    assert {:ok, %State{} = worker_state, pool_state} = Worker.init_worker(pool_state)
    dead_channel_pid = worker_state.channel.pid
    send(dead_channel_pid, :stop)
    refute Process.alive?(dead_channel_pid)

    assert {:ok, %State{} = client_state, %State{} = updated_worker_state, _pool_state} =
             Worker.handle_checkout(:checkout, self(), worker_state, pool_state)

    assert client_state.lifecycle == :ready
    assert updated_worker_state.lifecycle == :ready
    assert updated_worker_state.channel.pid != dead_channel_pid
    assert_received {:fake_amqp, :open_connection, :recover_dead_resource}
    assert_received {:fake_amqp, :open_channel, :recover_dead_resource}
  end

  test "worker is marked stale on DOWN and next checkout recovers it" do
    assert {:ok, pool_state} =
             Worker.init_pool(connection: [test_pid: self(), label: :down_recovery], pool_size: 1)

    assert {:ok, %State{} = worker_state, pool_state} = Worker.init_worker(pool_state)

    assert {:ok, %State{} = stale_state} =
             Worker.handle_info(
               {:DOWN, worker_state.channel_monitor_ref, :process, worker_state.channel.pid,
                :killed},
               worker_state
             )

    assert stale_state.lifecycle == :stale

    assert {:ok, %State{} = recovered_client_state, %State{} = recovered_worker_state,
            _pool_state} =
             Worker.handle_checkout(:checkout, self(), stale_state, pool_state)

    assert recovered_client_state.lifecycle == :ready
    assert recovered_worker_state.lifecycle == :ready
    assert_received {:fake_amqp, :open_connection, :down_recovery}
    assert_received {:fake_amqp, :open_channel, :down_recovery}
  end

  test "recovery failure surfaces pool error and checkin discards the worker" do
    step_agent = start_supervised!({Agent, fn -> 0 end})

    channel_open_fun = fn {:open_channel, _label} ->
      Agent.get_and_update(step_agent, fn step ->
        if step == 0 do
          {:ok, step + 1}
        else
          {{:error, :recovery_channel_open_failed}, step + 1}
        end
      end)
    end

    assert {:ok, pool_state} =
             Worker.init_pool(
               connection: [
                 test_pid: self(),
                 label: :recovery_failure,
                 channel_open_fun: channel_open_fun
               ],
               pool_size: 1
             )

    assert {:ok, %State{} = worker_state, pool_state} = Worker.init_worker(pool_state)

    assert {:ok, %State{} = stale_state} =
             Worker.handle_info(
               {:DOWN, worker_state.channel_monitor_ref, :process, worker_state.channel.pid,
                :killed},
               worker_state
             )

    assert {:ok, {:pool_error, %RecoveryError{} = error}, %State{} = failed_worker_state,
            _pool_state} =
             Worker.handle_checkout(:checkout, self(), stale_state, pool_state)

    assert error.stage == :channel_open
    assert error.reason == :recovery_channel_open_failed
    assert failed_worker_state.lifecycle == :closing

    assert {:remove, {:discard_worker, %RecoveryError{}}, _pool_state} =
             Worker.handle_checkin(failed_worker_state, self(), failed_worker_state, pool_state)
  end

  defp setup_ready_channel(%{label: label}) do
    send(self(), {:channel_setup_called, label})
    :ok
  end

  defp pool_name(label) do
    {:global, {__MODULE__, label, System.unique_integer([:positive])}}
  end

  defp resolve_name({:global, global_name}) do
    :global.whereis_name(global_name)
  end
end
