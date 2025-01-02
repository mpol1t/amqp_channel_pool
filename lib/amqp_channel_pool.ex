defmodule AMQPChannelPool do
  @moduledoc """
  A library for managing an AMQP channel pool with NimblePool.

  This module provides an abstraction over NimblePool to simplify working with
  AMQP connections and channels. It includes functions for starting the pool,
  checking out channels, and stopping the pool.
  """

  @doc """
  Starts the AMQP channel pool.

  ## Arguments

  - **opts** - A keyword list containing:
    - **:opts** - A map of options for the AMQP connection.
    - **:pool_size** - The number of workers in the pool (default: 10).

  ## Examples

      {:ok, _pid} = AMQPChannelPool.start_link(opts: [host: "localhost"], pool_size: 5)

  ## Returns

  - **{:ok, pid}** on success.
  - **{:error, reason}** on failure.
  """
  def start_link(opts) do
    pool_size = Keyword.get(opts, :pool_size, 10)
    connection_opts = Keyword.fetch!(opts, :opts)

    NimblePool.start_link(
      worker: {AMQPChannelPool.Worker, [opts: connection_opts]},
      name: __MODULE__,
      pool_size: pool_size,
      lazy: false
    )
  end

  @doc """
  Checks out an AMQP channel from the pool and executes the given function.

  ## Arguments

  - **fun** - A function that receives the checked-out channel and performs
    operations on it. The function must return the result of the operation.

  ## Examples

      AMQPChannelPool.checkout!(fn channel ->
        AMQP.Basic.publish(channel, "exchange_name", "routing_key", "message")
      end)

  ## Returns

  The result of the provided function.
  """
  def checkout!(fun) when is_function(fun, 1) do
    NimblePool.checkout!(
      __MODULE__,
      :checkout,
      fn _, %{channel: channel} = worker_state ->
        result = fun.(channel)
        {result, worker_state}
      end
    )
  end

  @doc """
  Defines the child specification for the pool.

  This function allows the module to be used directly as a child in a supervision tree.

  ## Arguments

  - **opts** - A keyword list containing the options for starting the pool.

  ## Returns

  A map defining the child specification.

  ## Examples

      children = [
        {AMQPChannelPool, opts: %{host: "localhost"}, pool_size: 5}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Stops the AMQP channel pool.

  This function shuts down the supervisor managing the pool, ensuring
  all resources are released properly.

  ## Examples

      :ok = AMQPChannelPool.stop()
  """
  def stop do
    Supervisor.stop(__MODULE__)
  end
end
