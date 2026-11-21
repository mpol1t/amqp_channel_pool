# Getting Started

Publish a message from an existing supervised Mix application. This example assumes RabbitMQ is listening on `localhost:5672` with the default virtual host `/` and local credentials `guest` / `guest`.

## Install the package

Add this entry to the dependency list in your application's `mix.exs`.

```elixir
{:amqp_channel_pool, "~> 0.3.0"}
```

From the project directory, fetch the dependency.

```bash
mix deps.get
```

## Start one pool with your application

Add this child to the existing `children` list in your application's `start/2` callback.

```elixir
{AMQPChannelPool, name: MyApp.PublisherPool, connection: [host: "localhost"], pool_size: 1}
```

The name `MyApp.PublisherPool` identifies the supervised pool process. Start the application in IEx.

```bash
iex -S mix
```

## Publish a message

In IEx, declare a demo queue and publish to it in one checkout.

```elixir
AMQPChannelPool.checkout(MyApp.PublisherPool, fn channel ->
  case AMQP.Queue.declare(channel, "demo.events") do
    {:ok, _queue_info} -> AMQP.Basic.publish(channel, "", "demo.events", "hello")
    {:error, reason} -> {:error, reason}
  end
end, [])
# => {:ok, :ok}
```

The outer `{:ok, result}` means the callback returned normally. The inner
`:ok` is the publish call's result. The empty exchange name (`""`) selects
RabbitMQ's default exchange, which routes by queue name. If declaration or
publishing returns `{:error, reason}`, checkout returns `{:ok, {:error, reason}}`.
Broker confirmation and consumer acknowledgement are separate operations.

For a reusable publisher, continue to [Enqueue a background job](publishing_examples.md#enqueue-a-background-job).
