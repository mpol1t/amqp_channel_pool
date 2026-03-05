defmodule AMQPChannelPool.TelemetryTest.FakeAMQPClient do
  def open_connection(connection_opts) do
    label = Keyword.fetch!(connection_opts, :label)
    test_pid = Keyword.fetch!(connection_opts, :test_pid)
    channel_open_fun = Keyword.get(connection_opts, :channel_open_fun)

    {:ok,
     %{
       pid: spawn_resource(),
       label: label,
       test_pid: test_pid,
       channel_open_fun: channel_open_fun
     }}
  end

  def open_channel(connection) do
    open_result =
      if is_function(connection.channel_open_fun, 1) do
        connection.channel_open_fun.({:open_channel, connection.label})
      else
        :ok
      end

    case open_result do
      :ok ->
        {:ok, %{pid: spawn_resource(), label: connection.label, test_pid: connection.test_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def close_connection(connection) do
    stop_resource(connection.pid)
    :ok
  end

  def close_channel(channel) do
    stop_resource(channel.pid)
    :ok
  end

  defp spawn_resource do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_resource(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end
end

defmodule AMQPChannelPool.TelemetryTest.OkWorker do
  @behaviour NimblePool

  @impl true
  def init_pool(opts), do: {:ok, opts}

  @impl true
  def init_worker(pool_state), do: {:ok, %{channel: :ok_channel}, pool_state}

  @impl true
  def handle_checkout(_command, _from, worker_state, pool_state),
    do: {:ok, worker_state, worker_state, pool_state}

  @impl true
  def handle_checkin(_client_state, _from, worker_state, pool_state),
    do: {:ok, worker_state, pool_state}

  @impl true
  def terminate_worker(_reason, _worker_state, pool_state), do: {:ok, pool_state}
end

defmodule AMQPChannelPool.TelemetryTest.PoolErrorWorker do
  @behaviour NimblePool

  alias AMQPChannelPool.Worker.RecoveryError

  @impl true
  def init_pool(opts), do: {:ok, opts}

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
  def handle_checkin(_client_state, _from, worker_state, pool_state),
    do: {:ok, worker_state, pool_state}

  @impl true
  def terminate_worker(_reason, _worker_state, pool_state), do: {:ok, pool_state}
end

defmodule AMQPChannelPool.TelemetryTest do
  use ExUnit.Case, async: false

  alias AMQPChannelPool.Worker
  alias AMQPChannelPool.Worker.RecoveryError
  alias AMQPChannelPool.Worker.StartupError

  @events [
    [:amqp_channel_pool, :checkout, :start],
    [:amqp_channel_pool, :checkout, :stop],
    [:amqp_channel_pool, :checkout, :exception],
    [:amqp_channel_pool, :worker, :init, :start],
    [:amqp_channel_pool, :worker, :init, :stop],
    [:amqp_channel_pool, :worker, :init, :exception],
    [:amqp_channel_pool, :worker, :recover, :start],
    [:amqp_channel_pool, :worker, :recover, :stop],
    [:amqp_channel_pool, :worker, :recover, :exception],
    [:amqp_channel_pool, :worker, :discard],
    [:amqp_channel_pool, :worker, :terminate]
  ]

  setup do
    handler_id = "amqp-channel-pool-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        self()
      )

    original_worker_module = Application.get_env(:amqp_channel_pool, :worker_module)
    original_amqp_client_module = Application.get_env(:amqp_channel_pool, :amqp_client_module)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if original_worker_module do
        Application.put_env(:amqp_channel_pool, :worker_module, original_worker_module)
      else
        Application.delete_env(:amqp_channel_pool, :worker_module)
      end

      if original_amqp_client_module do
        Application.put_env(:amqp_channel_pool, :amqp_client_module, original_amqp_client_module)
      else
        Application.delete_env(:amqp_channel_pool, :amqp_client_module)
      end
    end)

    :ok
  end

  test "checkout success emits start and stop telemetry with stable metadata" do
    Application.put_env(
      :amqp_channel_pool,
      :worker_module,
      AMQPChannelPool.TelemetryTest.OkWorker
    )

    name = pool_name(:checkout_success)
    {:ok, pid} = AMQPChannelPool.start_link(name: name, connection: [label: :checkout_success])
    on_exit(fn -> stop_pool(pid, name) end)

    assert {:ok, :ok} = AMQPChannelPool.checkout(name, fn _channel -> :ok end, timeout: 250)

    assert_receive {:telemetry_event, [:amqp_channel_pool, :checkout, :start], measurements,
                    metadata}

    assert is_integer(measurements.system_time)
    assert metadata.pool == name
    assert metadata.timeout == 250

    assert_receive {:telemetry_event, [:amqp_channel_pool, :checkout, :stop], stop_measurements,
                    stop_metadata}

    assert is_integer(stop_measurements.duration)
    assert stop_measurements.duration >= 0
    assert stop_metadata.pool == name
    assert stop_metadata.timeout == 250
    assert stop_metadata.result == :ok
    assert is_pid(stop_metadata.worker_pid)
    assert stop_metadata.worker_state == [:channel]
    assert Map.has_key?(stop_metadata, :recovery_kind)
    assert Map.has_key?(stop_metadata, :reason)
  end

  test "callback exception emits checkout exception telemetry without conversion to pool error" do
    Application.put_env(
      :amqp_channel_pool,
      :worker_module,
      AMQPChannelPool.TelemetryTest.OkWorker
    )

    name = pool_name(:callback_exception)
    {:ok, pid} = AMQPChannelPool.start_link(name: name, connection: [label: :callback_exception])
    on_exit(fn -> stop_pool(pid, name) end)

    assert_raise RuntimeError, "callback failed", fn ->
      AMQPChannelPool.checkout(name, fn _channel -> raise "callback failed" end, timeout: 300)
    end

    assert_receive {:telemetry_event, [:amqp_channel_pool, :checkout, :exception], measurements,
                    metadata}

    assert is_integer(measurements.duration)
    assert measurements.duration >= 0
    assert metadata.pool == name
    assert metadata.timeout == 300
    assert metadata.result == :callback_exception
    assert is_pid(metadata.worker_pid)
    assert metadata.kind == :error
    assert %RuntimeError{message: "callback failed"} = metadata.reason
  end

  test "pool-layer failure emits checkout stop telemetry with pool_error result" do
    Application.put_env(
      :amqp_channel_pool,
      :worker_module,
      AMQPChannelPool.TelemetryTest.PoolErrorWorker
    )

    name = pool_name(:pool_error)
    {:ok, pid} = AMQPChannelPool.start_link(name: name, connection: [label: :pool_error])
    on_exit(fn -> stop_pool(pid, name) end)

    assert {:error, %RecoveryError{} = error} =
             AMQPChannelPool.checkout(name, fn _channel -> :ok end, timeout: 400)

    assert error.reason == :setup_failed_during_recovery

    assert_receive {:telemetry_event, [:amqp_channel_pool, :checkout, :stop], measurements,
                    metadata}

    assert is_integer(measurements.duration)
    assert metadata.pool == name
    assert metadata.timeout == 400
    assert metadata.result == :pool_error
    assert is_pid(metadata.worker_pid)
    assert metadata.worker_state == :pool_error
    assert %RecoveryError{} = metadata.reason
  end

  test "worker init success emits init start and stop telemetry" do
    Application.put_env(
      :amqp_channel_pool,
      :amqp_client_module,
      AMQPChannelPool.TelemetryTest.FakeAMQPClient
    )

    pool = pool_name(:init_success)

    assert {:ok, pool_state} =
             Worker.init_pool(
               pool: pool,
               connection: [label: :init_success, test_pid: self()],
               pool_size: 1
             )

    assert {:ok, worker_state, _pool_state} = Worker.init_worker(pool_state)
    assert worker_state.lifecycle == :ready

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :init, :start],
                    start_measurements, start_metadata}

    assert is_integer(start_measurements.system_time)
    assert start_metadata.pool == pool
    assert is_pid(start_metadata.worker_pid)
    assert start_metadata.worker_state == :starting

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :init, :stop], measurements,
                    metadata}

    assert is_integer(measurements.duration)
    assert measurements.duration >= 0
    assert metadata.pool == pool
    assert is_pid(metadata.worker_pid)
    assert metadata.worker_state == :ready
    assert metadata.result == :ok
  end

  test "worker init failure emits init exception telemetry" do
    Application.put_env(
      :amqp_channel_pool,
      :amqp_client_module,
      AMQPChannelPool.TelemetryTest.FakeAMQPClient
    )

    assert {:stop, %StartupError{} = startup_error} =
             Worker.init_pool(
               pool: pool_name(:init_exception),
               connection: [
                 label: :init_exception,
                 test_pid: self(),
                 channel_open_fun: fn _ -> {:error, :cannot_open_channel} end
               ],
               pool_size: 1
             )

    assert startup_error.stage == :channel_open

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :init, :start],
                    start_measurements, start_metadata}

    assert is_integer(start_measurements.system_time)
    assert start_metadata.pool != nil

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :init, :exception],
                    measurements, metadata}

    assert is_integer(measurements.duration)
    assert metadata.result == :error
    assert {:channel_open, :cannot_open_channel} = metadata.reason
    assert is_pid(metadata.worker_pid)
  end

  test "worker recovery success emits recover start and stop telemetry" do
    Application.put_env(
      :amqp_channel_pool,
      :amqp_client_module,
      AMQPChannelPool.TelemetryTest.FakeAMQPClient
    )

    pool = pool_name(:recover_success)

    assert {:ok, pool_state} =
             Worker.init_pool(
               pool: pool,
               connection: [label: :recover_success, test_pid: self()],
               pool_size: 1
             )

    assert {:ok, worker_state, pool_state} = Worker.init_worker(pool_state)

    assert {:ok, stale_state} =
             Worker.handle_info(
               {:DOWN, worker_state.channel_monitor_ref, :process, worker_state.channel.pid,
                :killed},
               worker_state
             )

    assert {:ok, recovered_client_state, recovered_worker_state, _pool_state} =
             Worker.handle_checkout(:checkout, self(), stale_state, pool_state)

    assert recovered_client_state.lifecycle == :ready
    assert recovered_worker_state.lifecycle == :ready

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :recover, :start],
                    recover_start_measurements, recover_start_metadata}

    assert is_integer(recover_start_measurements.system_time)
    assert recover_start_metadata.pool == pool
    assert is_pid(recover_start_metadata.worker_pid)
    assert recover_start_metadata.worker_state == :recovering
    assert recover_start_metadata.recovery_kind == :stale

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :recover, :stop],
                    recover_stop_measurements, recover_stop_metadata}

    assert is_integer(recover_stop_measurements.duration)
    assert recover_stop_measurements.duration >= 0
    assert recover_stop_metadata.pool == pool
    assert is_pid(recover_stop_metadata.worker_pid)
    assert recover_stop_metadata.worker_state == :ready
    assert recover_stop_metadata.recovery_kind == :stale
    assert recover_stop_metadata.result == :ok
  end

  test "worker recovery failure emits recover exception plus discard and terminate events" do
    Application.put_env(
      :amqp_channel_pool,
      :amqp_client_module,
      AMQPChannelPool.TelemetryTest.FakeAMQPClient
    )

    step_agent = start_supervised!({Agent, fn -> 0 end})

    channel_open_fun = fn _ ->
      Agent.get_and_update(step_agent, fn step ->
        if step == 0 do
          {:ok, step + 1}
        else
          {{:error, :recovery_open_failed}, step + 1}
        end
      end)
    end

    pool = pool_name(:recover_exception)

    assert {:ok, pool_state} =
             Worker.init_pool(
               pool: pool,
               connection: [
                 label: :recover_exception,
                 test_pid: self(),
                 channel_open_fun: channel_open_fun
               ],
               pool_size: 1
             )

    assert {:ok, worker_state, pool_state} = Worker.init_worker(pool_state)

    assert {:ok, stale_state} =
             Worker.handle_info(
               {:DOWN, worker_state.channel_monitor_ref, :process, worker_state.channel.pid,
                :killed},
               worker_state
             )

    assert {:ok, {:pool_error, %RecoveryError{} = error}, failed_worker_state, pool_state} =
             Worker.handle_checkout(:checkout, self(), stale_state, pool_state)

    assert error.reason == :recovery_open_failed

    assert {:remove, {:discard_worker, %RecoveryError{}}, pool_state} =
             Worker.handle_checkin(failed_worker_state, self(), failed_worker_state, pool_state)

    assert {:ok, _pool_state} =
             Worker.terminate_worker(:shutdown, failed_worker_state, pool_state)

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :recover, :start],
                    recover_start_measurements, recover_start_metadata}

    assert is_integer(recover_start_measurements.system_time)
    assert recover_start_metadata.pool == pool

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :recover, :exception],
                    recover_exception_measurements, recover_exception_metadata}

    assert is_integer(recover_exception_measurements.duration)
    assert recover_exception_metadata.pool == pool
    assert recover_exception_metadata.result == :error
    assert recover_exception_metadata.recovery_kind == :stale
    assert {:channel_open, :recovery_open_failed} = recover_exception_metadata.reason

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :discard],
                    discard_measurements, discard_metadata}

    assert discard_measurements == %{}
    assert discard_metadata.pool == pool
    assert discard_metadata.result == :discarded
    assert %RecoveryError{} = discard_metadata.reason

    assert_receive {:telemetry_event, [:amqp_channel_pool, :worker, :terminate],
                    terminate_measurements, terminate_metadata}

    assert terminate_measurements == %{}
    assert terminate_metadata.pool == pool
    assert terminate_metadata.result == :terminated
  end

  defp pool_name(label) do
    {:global, {__MODULE__, label, System.unique_integer([:positive])}}
  end

  defp stop_pool(pid, name) do
    if Process.alive?(pid) do
      _ = catch_exit(AMQPChannelPool.stop(name))
    end
  end
end
