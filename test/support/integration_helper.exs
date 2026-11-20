defmodule AMQPChannelPool.IntegrationHelpers do
  import ExUnit.Assertions

  @default_checkout_timeout 1_000
  @default_wait_timeout 5_000
  @default_wait_interval 100

  def rabbitmq_connection_opts do
    host = System.get_env("AMQP_TEST_HOST", "127.0.0.1")
    port = System.get_env("AMQP_TEST_PORT", "5672") |> String.to_integer()
    username = System.get_env("AMQP_TEST_USERNAME", "guest")
    password = System.get_env("AMQP_TEST_PASSWORD", "guest")

    [host: host, port: port, username: username, password: password]
  end

  def wait_for_broker!(connection_opts, timeout_ms \\ 30_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_broker_ready(connection_opts, deadline_ms)
  end

  def unique_pool_name(test_module, label) do
    {:global, {test_module, label, System.unique_integer([:positive])}}
  end

  def stop_pool(pid, pool_name) do
    if Process.alive?(pid) do
      _ = catch_exit(AMQPChannelPool.stop(pool_name))
    end
  end

  def close_channel_in_checkout!(pool_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_checkout_timeout)

    AMQPChannelPool.checkout!(
      pool_name,
      fn channel ->
        :ok = AMQP.Channel.close(channel)
        channel.pid
      end,
      timeout: timeout
    )
  end

  def close_connection_in_checkout!(pool_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_checkout_timeout)

    AMQPChannelPool.checkout!(
      pool_name,
      fn channel ->
        :ok = AMQP.Connection.close(channel.conn)
        {channel.conn.pid, channel.pid}
      end,
      timeout: timeout
    )
  end

  def eventually!(fun, opts \\ []) when is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout, @default_wait_timeout)
    interval_ms = Keyword.get(opts, :interval, @default_wait_interval)
    description = Keyword.get(opts, :description, "condition")
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    wait_until(fun, deadline_ms, interval_ms, description)
  end

  def attach_telemetry!(events, target_pid) when is_list(events) and is_pid(target_pid) do
    handler_id = "amqp-channel-pool-integration-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, measurements, metadata})
        end,
        target_pid
      )

    handler_id
  end

  def detach_telemetry(handler_id), do: :telemetry.detach(handler_id)

  defp wait_until_broker_ready(connection_opts, deadline_ms) do
    case AMQP.Connection.open(connection_opts) do
      {:ok, connection} ->
        :ok = AMQP.Connection.close(connection)

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("RabbitMQ did not become ready before timeout")
        end

        Process.sleep(500)
        wait_until_broker_ready(connection_opts, deadline_ms)
    end
  end

  defp wait_until(fun, deadline_ms, interval_ms, description) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("Timed out waiting for #{description}")
      end

      Process.sleep(interval_ms)
      wait_until(fun, deadline_ms, interval_ms, description)
    end
  end
end
