defmodule AMQPChannelPool.Worker do
  @moduledoc false
  @behaviour NimblePool

  require Logger

  @impl true
  @doc false
  def init_pool(opts) do
    {:ok, opts}
  end

  @impl true
  @doc false
  def init_worker([opts: connection_opts] = pool_state) do
    Logger.debug("AMQPChannelPool.Worker starting...")

    {:ok, conn} = AMQP.Connection.open(connection_opts)
    {:ok, channel} = AMQP.Channel.open(conn)

    {:ok, %{channel: channel, conn: conn}, pool_state}
  end

  @impl true
  @doc false
  def handle_checkout(_command, _from, worker_state, pool_state) do
    {:ok, worker_state, worker_state, pool_state}
  end

  @impl true
  @doc false
  def handle_checkin(_client_state, _from, worker_state, pool_state) do
    {:ok, worker_state, pool_state}
  end

  @impl true
  @doc false
  def terminate_worker(_reason, %{channel: channel, conn: conn}, pool_state) do
    Logger.debug("AMQPChannelPool.Worker terminating...")

    AMQP.Channel.close(channel)
    AMQP.Connection.close(conn)
    {:ok, pool_state}
  end
end
