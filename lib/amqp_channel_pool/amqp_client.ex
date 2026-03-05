defmodule AMQPChannelPool.AMQPClient do
  @moduledoc false

  @callback open_connection(keyword()) :: {:ok, term()} | {:error, term()}
  @callback open_channel(term()) :: {:ok, term()} | {:error, term()}
  @callback close_connection(term()) :: term()
  @callback close_channel(term()) :: term()

  def open_connection(connection_opts) do
    AMQP.Connection.open(connection_opts)
  end

  def open_channel(connection) do
    AMQP.Channel.open(connection)
  end

  def close_connection(connection) do
    AMQP.Connection.close(connection)
  end

  def close_channel(channel) do
    AMQP.Channel.close(channel)
  end
end
