defmodule AMQPChannelPool.RecoveryIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AMQPChannelPool.IntegrationHelpers
  alias AMQPChannelPool.Worker.RecoveryError

  setup_all do
    connection_opts = IntegrationHelpers.rabbitmq_connection_opts()
    IntegrationHelpers.wait_for_broker!(connection_opts)
    :ok
  end

  test "the replacement channel publishes a message after channel closure" do
    pool_name = IntegrationHelpers.unique_pool_name(__MODULE__, :channel_closure)

    {:ok, pid} =
      AMQPChannelPool.start_link(
        name: pool_name,
        connection: IntegrationHelpers.rabbitmq_connection_opts(),
        pool_size: 1
      )

    on_exit(fn -> IntegrationHelpers.stop_pool(pid, pool_name) end)

    initial_channel_pid =
      AMQPChannelPool.checkout!(pool_name, fn channel -> channel.pid end, timeout: 1_000)

    monitor_ref = Process.monitor(initial_channel_pid)
    assert initial_channel_pid == IntegrationHelpers.close_channel_in_checkout!(pool_name)
    assert_receive {:DOWN, ^monitor_ref, :process, ^initial_channel_pid, _reason}, 5_000

    payload = "published after closing channel #{inspect(initial_channel_pid)}"

    assert {:ok, recovered_channel_pid} =
             AMQPChannelPool.checkout(
               pool_name,
               fn channel ->
                 assert {:ok, %{queue: queue}} = AMQP.Queue.declare(channel, "", exclusive: true)
                 assert :ok = AMQP.Basic.publish(channel, "", queue, payload)
                 assert {:ok, ^payload, _metadata} = AMQP.Basic.get(channel, queue, no_ack: true)
                 channel.pid
               end,
               timeout: 1_000
             )

    assert recovered_channel_pid != initial_channel_pid
  end

  test "connection closure is detected and next checkout recovers before handing out resources" do
    pool_name = IntegrationHelpers.unique_pool_name(__MODULE__, :connection_closure)

    {:ok, pid} =
      AMQPChannelPool.start_link(
        name: pool_name,
        connection: IntegrationHelpers.rabbitmq_connection_opts(),
        pool_size: 1
      )

    on_exit(fn -> IntegrationHelpers.stop_pool(pid, pool_name) end)

    {initial_connection_pid, initial_channel_pid} =
      AMQPChannelPool.checkout!(
        pool_name,
        fn channel ->
          {channel.conn.pid, channel.pid}
        end,
        timeout: 1_000
      )

    {closed_connection_pid, closed_channel_pid} =
      IntegrationHelpers.close_connection_in_checkout!(pool_name)

    assert closed_connection_pid == initial_connection_pid
    assert closed_channel_pid == initial_channel_pid

    # Connection and channel process termination may propagate asynchronously.
    # Wait until both old processes are down before asserting replacement.
    :ok =
      IntegrationHelpers.eventually!(fn -> not Process.alive?(initial_connection_pid) end,
        description: "initial connection process shutdown"
      )

    :ok =
      IntegrationHelpers.eventually!(fn -> not Process.alive?(initial_channel_pid) end,
        description: "initial channel process shutdown after connection close"
      )

    assert {:ok, {recovered_connection_pid, recovered_channel_pid}} =
             AMQPChannelPool.checkout(
               pool_name,
               fn channel ->
                 assert Process.alive?(channel.conn.pid)
                 assert Process.alive?(channel.pid)
                 {channel.conn.pid, channel.pid}
               end,
               timeout: 1_000
             )

    assert recovered_connection_pid != initial_connection_pid
    assert recovered_channel_pid != initial_channel_pid
  end

  test "successful recovery reapplies channel_setup" do
    pool_name = IntegrationHelpers.unique_pool_name(__MODULE__, :setup_reapplied)
    setup_counter = start_supervised!({Agent, fn -> 0 end})

    channel_setup = fn _channel ->
      Agent.update(setup_counter, &(&1 + 1))
      :ok
    end

    {:ok, pid} =
      AMQPChannelPool.start_link(
        name: pool_name,
        connection: IntegrationHelpers.rabbitmq_connection_opts(),
        channel_setup: channel_setup,
        pool_size: 1
      )

    on_exit(fn -> IntegrationHelpers.stop_pool(pid, pool_name) end)

    assert Agent.get(setup_counter, & &1) == 1

    closed_channel_pid = IntegrationHelpers.close_channel_in_checkout!(pool_name)

    :ok =
      IntegrationHelpers.eventually!(fn -> not Process.alive?(closed_channel_pid) end,
        description: "closed channel process shutdown before recovery"
      )

    assert {:ok, _channel_pid} =
             AMQPChannelPool.checkout(pool_name, fn channel -> channel.pid end, timeout: 1_000)

    assert Agent.get(setup_counter, & &1) == 2
  end

  test "setup failure during recovery returns a clear pool-layer failure and worker is replaced" do
    pool_name = IntegrationHelpers.unique_pool_name(__MODULE__, :setup_recovery_failure)
    setup_counter = start_supervised!({Agent, fn -> 0 end})

    channel_setup = fn _channel ->
      call_number =
        Agent.get_and_update(setup_counter, fn count ->
          {count + 1, count + 1}
        end)

      if call_number == 2 do
        {:error, :setup_failed_during_recovery}
      else
        :ok
      end
    end

    {:ok, pid} =
      AMQPChannelPool.start_link(
        name: pool_name,
        connection: IntegrationHelpers.rabbitmq_connection_opts(),
        channel_setup: channel_setup,
        pool_size: 1
      )

    on_exit(fn -> IntegrationHelpers.stop_pool(pid, pool_name) end)

    initial_channel_pid =
      AMQPChannelPool.checkout!(pool_name, fn channel -> channel.pid end, timeout: 1_000)

    closed_channel_pid = IntegrationHelpers.close_channel_in_checkout!(pool_name)

    assert closed_channel_pid == initial_channel_pid

    :ok =
      IntegrationHelpers.eventually!(fn -> not Process.alive?(closed_channel_pid) end,
        description: "closed channel process shutdown before setup-failure recovery"
      )

    # The next checkout is expected to hit exactly one recovery attempt.
    # This attempt re-runs setup and deterministically fails on call 2.
    assert {:error, %RecoveryError{} = error} =
             AMQPChannelPool.checkout(
               pool_name,
               fn _channel -> flunk("failed recovery invoked its callback") end,
               timeout: 1_000
             )

    assert error.stage == :channel_setup
    assert error.reason == :setup_failed_during_recovery

    assert {:ok, replaced_channel_pid} =
             AMQPChannelPool.checkout(pool_name, fn channel -> channel.pid end, timeout: 1_000)

    assert replaced_channel_pid != initial_channel_pid

    assert Agent.get(setup_counter, & &1) == 3
  end

  test "recovery checkout assertions remain stable under eventual broker shutdown propagation" do
    pool_name = IntegrationHelpers.unique_pool_name(__MODULE__, :eventual_stability)

    {:ok, pid} =
      AMQPChannelPool.start_link(
        name: pool_name,
        connection: IntegrationHelpers.rabbitmq_connection_opts(),
        pool_size: 1
      )

    on_exit(fn -> IntegrationHelpers.stop_pool(pid, pool_name) end)

    old_channel_pid =
      AMQPChannelPool.checkout!(pool_name, fn channel -> channel.pid end, timeout: 1_000)

    _closed_channel_pid = IntegrationHelpers.close_channel_in_checkout!(pool_name)

    :ok =
      IntegrationHelpers.eventually!(fn -> not Process.alive?(old_channel_pid) end,
        description: "old channel process shutdown in eventual stability scenario"
      )

    :ok =
      IntegrationHelpers.eventually!(
        fn ->
          case AMQPChannelPool.checkout(pool_name, fn channel -> channel.pid end, timeout: 1_000) do
            {:ok, new_channel_pid} when new_channel_pid != old_channel_pid -> true
            _ -> false
          end
        end,
        description: "successful checkout with replaced channel pid"
      )
  end

  test "legacy stable closure flow remains deterministic" do
    pool_name = IntegrationHelpers.unique_pool_name(__MODULE__, :legacy_stable_closure)

    {:ok, pid} =
      AMQPChannelPool.start_link(
        name: pool_name,
        connection: IntegrationHelpers.rabbitmq_connection_opts(),
        pool_size: 1
      )

    on_exit(fn -> IntegrationHelpers.stop_pool(pid, pool_name) end)

    initial_channel_pid =
      AMQPChannelPool.checkout!(pool_name, fn channel -> channel.pid end, timeout: 1_000)

    assert initial_channel_pid == IntegrationHelpers.close_channel_in_checkout!(pool_name)

    :ok =
      IntegrationHelpers.eventually!(fn -> not Process.alive?(initial_channel_pid) end,
        description: "initial channel process shutdown in legacy closure flow"
      )

    assert {:ok, _channel_pid} =
             AMQPChannelPool.checkout(pool_name, fn channel -> channel.pid end, timeout: 1_000)
  end
end
