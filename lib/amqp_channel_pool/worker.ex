defmodule AMQPChannelPool.Worker do
  @moduledoc false
  @behaviour NimblePool

  require Logger

  @impl true
  @doc false
  @doc """
  Initializes the pool with the given options.

  ## Arguments

  - `opts` - A keyword list containing the configuration options for the pool.
  """
  def init_pool(opts) do
    {:ok, opts}
  end

  @impl true
  @doc false
  @doc """
  Initializes a worker with a new AMQP connection and channel.

  ## Arguments

  - `pool_state` - A list containing the pool's state, including the AMQP connection options.

  ## Returns

  A tuple containing the worker's initial state and the updated pool state.
  """
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
  @doc """
  Terminates the worker by closing the AMQP connection and channel.

  ## Arguments

  - `_reason` - The reason for termination (unused).
  - `worker_state` - A map containing the `channel` and `conn` to be terminated.
  - `pool_state` - The current state of the pool.

  ## Returns

  A tuple containing the updated pool state.
  """
  def terminate_worker(_reason, %{channel: channel, conn: conn}, pool_state) do
    Logger.debug("AMQPChannelPool.Worker terminating...")

    AMQP.Channel.close(channel)
    AMQP.Connection.close(conn)
    {:ok, pool_state}
  end
end
