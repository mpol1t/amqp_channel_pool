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
           label: label,
           test_pid: test_pid,
           opts: connection_opts,
           channel_open_fun: channel_open_fun,
           channel_open_result: Keyword.get(connection_opts, :channel_open_result, :ok)
         }
         |> with_resource_pid(:connection)}

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
           connection_pid: Map.get(connection, :pid),
           label: connection.label,
           test_pid: connection.test_pid,
           opts: connection.opts
         }
         |> with_resource_pid(:channel)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def close_connection(connection), do: close_resource(connection, :connection, :close_connection)
  def close_channel(channel), do: close_resource(channel, :channel, :close_channel)

  defp with_resource_pid(resource, kind) do
    if Keyword.get(resource.opts, :missing_pid) == kind do
      resource
    else
      Map.put(resource, :pid, spawn_resource())
    end
  end

  defp close_resource(resource, kind, action) do
    send(resource.test_pid, {:fake_amqp, action, resource.label})

    if pid = Map.get(resource, :pid), do: send(pid, :stop)

    if close_fun = Keyword.get(resource.opts, :close_fun), do: close_fun.(kind)
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
end

defmodule AMQPChannelPool.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AMQPChannelPool
  alias AMQPChannelPool.IntegrationHelpers
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

    assert receive_ready_step(:ready) == :open_connection
    assert receive_ready_step(:ready) == :open_channel
    assert receive_ready_step(:ready) == :channel_setup
    refute_received {:channel_setup_called, :ready}

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

  test "startup rolls back both workers when the second worker's setup fails" do
    Process.flag(:trap_exit, true)
    name = pool_name(:partial_startup)
    test_pid = self()
    attempts = start_supervised!({Agent, fn -> 0 end})

    init_events =
      for event <- [:start, :stop, :exception], do: [:amqp_channel_pool, :worker, :init, event]

    handler = IntegrationHelpers.attach_telemetry!(init_events, test_pid)
    on_exit(fn -> IntegrationHelpers.detach_telemetry(handler) end)

    channel_setup = fn channel ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:setup_resources, attempt, channel.connection_pid, channel.pid})

      case attempt do
        1 -> :ok
        2 -> {:error, :second_setup_failed}
      end
    end

    assert {:error, %StartupError{stage: :channel_setup, reason: :second_setup_failed} = error} =
             AMQPChannelPool.start_link(
               name: name,
               connection: [test_pid: test_pid, label: :partial_startup],
               channel_setup: channel_setup,
               pool_size: 2
             )

    assert Exception.message(error) ==
             "worker startup failed during :channel_setup: :second_setup_failed"

    for {event, lifecycle} <- [
          start: :starting,
          stop: :ready,
          start: :starting,
          exception: :starting
        ] do
      assert_received {:telemetry_event, [:amqp_channel_pool, :worker, :init, actual], _,
                       %{pool: ^name, worker_state: state}}

      assert {actual, state} == {event, lifecycle}
    end

    refute_received {:telemetry_event, [:amqp_channel_pool, :worker, :init, _], _, %{pool: ^name}}

    assert_receive {:setup_resources, 1, first_connection, first_channel}, 1_000
    assert_receive {:setup_resources, 2, second_connection, second_channel}, 1_000

    resources = [first_connection, first_channel, second_connection, second_channel]
    assert length(Enum.uniq(resources)) == 4

    for pid <- resources do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    for action <- [
          :open_connection,
          :open_channel,
          :open_connection,
          :open_channel,
          :close_channel,
          :close_connection,
          :close_channel,
          :close_connection
        ] do
      assert_received {:fake_amqp, actual, :partial_startup}
      assert actual == action
    end

    refute_received {:fake_amqp, _, :partial_startup}
    assert resolve_name(name) == :undefined
  end

  test "startup rejects a setup callback with a return other than :ok or {:error, reason}" do
    assert {:stop, %StartupError{stage: :channel_setup, reason: {:invalid_return, :unexpected}}} =
             init_with_setup(:invalid_setup_return, fn _channel -> :unexpected end)

    assert_cleanup(:invalid_setup_return)
  end

  test "startup captures a raised setup error and still cleans up both resources" do
    assert {:stop,
            %StartupError{
              stage: :channel_setup,
              reason: {:raised, %RuntimeError{message: "setup raised"}, [_ | _]}
            }} =
             init_with_setup(:raised_setup, fn _channel -> raise "setup raised" end)

    assert_cleanup(:raised_setup)
  end

  test "startup captures setup throws and exits and still cleans up both resources" do
    assert {:stop, %StartupError{stage: :channel_setup, reason: {:throw, :setup_threw}}} =
             init_with_setup(:thrown_setup, fn _channel -> throw(:setup_threw) end)

    assert_cleanup(:thrown_setup)

    assert {:stop, %StartupError{stage: :channel_setup, reason: {:exit, :setup_exited}}} =
             init_with_setup(:exited_setup, fn _channel -> exit(:setup_exited) end)

    assert_cleanup(:exited_setup)
  end

  test "startup cleans up when a client resource has no monitorable pid" do
    for kind <- [:connection, :channel] do
      assert {:stop,
              %StartupError{
                stage: :monitor_installation,
                reason: {:missing_pid, ^kind, resource}
              }} =
               Worker.init_pool(
                 connection: [test_pid: self(), label: kind, missing_pid: kind],
                 pool_size: 1
               )

      refute Map.has_key?(resource, :pid)
      assert_cleanup(kind)
    end
  end

  test "cleanup continues when either AMQP close raises or exits" do
    for {kind, failure} <- [
          {:channel, fn -> raise "channel close raised" end},
          {:channel, fn -> exit(:channel_close_exited) end},
          {:connection, fn -> raise "connection close raised" end},
          {:connection, fn -> exit(:connection_close_exited) end}
        ] do
      close_fun = fn resource_kind ->
        if resource_kind == kind, do: failure.()
      end

      label = make_ref()

      assert {:stop, %StartupError{stage: :channel_setup, reason: :setup_failed}} =
               init_with_setup(label, fn _channel -> {:error, :setup_failed} end,
                 close_fun: close_fun
               )

      assert_cleanup(label)
    end
  end

  test "the pool retries worker replacement after a transient startup failure" do
    label = :replacement_retry
    attempts = start_supervised!({Agent, fn -> 0 end})
    name = pool_name(label)

    setup = fn _channel ->
      case Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end) do
        2 -> {:error, :replacement_setup_failed}
        _ -> :ok
      end
    end

    start_supervised!(
      {AMQPChannelPool,
       name: name,
       connection: [test_pid: self(), label: label],
       channel_setup: setup,
       pool_size: 1}
    )

    first_channel = AMQPChannelPool.checkout!(name, & &1.pid, timeout: 1_000)

    log =
      capture_log(fn ->
        assert_raise RuntimeError, "discard original channel", fn ->
          AMQPChannelPool.checkout!(name, fn _ -> raise "discard original channel" end,
            timeout: 1_000
          )
        end

        replacement = AMQPChannelPool.checkout!(name, & &1.pid, timeout: 1_000)
        assert replacement != first_channel
        assert Process.alive?(replacement)
      end)

    assert log =~ "worker startup failed during :channel_setup: :replacement_setup_failed"
    assert Agent.get(attempts, & &1) == 3
  end

  for resource <- [:connection, :channel] do
    test "checkout recovers a dead #{resource} before its monitor notification is handled" do
      resource = unquote(resource)

      assert {:ok, pool_state} =
               Worker.init_pool(connection: [test_pid: self(), label: resource], pool_size: 1)

      assert {:ok, %State{} = worker, pool_state} = Worker.init_worker(pool_state)
      assert_received {:fake_amqp, :open_connection, ^resource}
      assert_received {:fake_amqp, :open_channel, ^resource}

      %{pid: dead_pid} = Map.fetch!(worker, resource)
      monitor_ref = Process.monitor(dead_pid)
      send(dead_pid, :stop)
      assert_receive {:DOWN, ^monitor_ref, :process, ^dead_pid, :normal}, 1_000

      assert {:ok, %State{lifecycle: :ready} = recovered, recovered, pool_state} =
               Worker.handle_checkout(:checkout, self(), worker, pool_state)

      assert recovered.metadata.stale_reason == {:checkout_validation_failed, :resource_not_alive}
      assert recovered.connection.pid != worker.connection.pid
      assert recovered.channel.pid != worker.channel.pid
      assert_received {:fake_amqp, :open_connection, ^resource}
      assert_received {:fake_amqp, :open_channel, ^resource}
      refute_received {:fake_amqp, :open_connection, ^resource}
      refute_received {:fake_amqp, :open_channel, ^resource}

      assert {:ok, _pool_state} = Worker.terminate_worker(:shutdown, recovered, pool_state)
    end
  end

  test "only matching monitor notifications mark a healthy worker stale" do
    label = :down_recovery

    assert {:ok, pool_state} =
             Worker.init_pool(connection: [test_pid: self(), label: label], pool_size: 1)

    assert {:ok, %State{} = worker, pool_state} = Worker.init_worker(pool_state)

    {unrelated, unrelated_ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^unrelated_ref, :process, ^unrelated, :normal} = down, 1_000
    assert {:ok, ^worker} = Worker.handle_info(down, worker)
    assert {:ok, ^worker} = Worker.handle_info(:unrelated, worker)

    assert {:ok, ^worker, ^worker, ^pool_state} =
             Worker.handle_checkout(:checkout, self(), worker, pool_state)

    %{
      connection: %{pid: connection},
      channel: %{pid: channel},
      connection_monitor_ref: connection_ref,
      channel_monitor_ref: channel_ref
    } = worker

    send(connection, :stop)

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :normal} = connection_down,
                   1_000

    assert {:ok, %State{lifecycle: :stale} = stale} = Worker.handle_info(connection_down, worker)
    assert stale.metadata.stale_reason == {:connection_down, :normal}

    send(channel, :stop)
    assert_receive {:DOWN, ^channel_ref, :process, ^channel, :normal} = channel_down, 1_000

    assert {:ok, %State{lifecycle: :stale} = channel_stale} =
             Worker.handle_info(channel_down, worker)

    assert channel_stale.metadata.stale_reason == {:channel_down, :normal}
    assert {:ok, ^stale} = Worker.handle_info(channel_down, stale)

    assert {:ok, %State{lifecycle: :ready} = recovered, recovered, pool_state} =
             Worker.handle_checkout(:checkout, self(), stale, pool_state)

    assert recovered.connection.pid != connection
    assert recovered.channel.pid != channel
    assert {:ok, _pool_state} = Worker.terminate_worker(:shutdown, recovered, pool_state)
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

  defp receive_ready_step(label) do
    receive do
      {:fake_amqp, action, ^label} -> action
      {:channel_setup_called, ^label} -> :channel_setup
    after
      1_000 -> flunk("missing setup step for #{inspect(label)}")
    end
  end

  defp init_with_setup(label, channel_setup, client_opts \\ []) do
    Worker.init_pool(
      connection: [test_pid: self(), label: label] ++ client_opts,
      channel_setup: channel_setup,
      pool_size: 1
    )
  end

  defp assert_cleanup(label) do
    for action <- [:open_connection, :open_channel, :close_channel, :close_connection] do
      assert_received {:fake_amqp, actual, ^label}
      assert actual == action
    end

    refute_received {:fake_amqp, _, ^label}
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
