# Publishing Examples

## Enqueue a background job

When the same application publishes many receipt jobs, move queue declaration into `:channel_setup`. `enqueue/1` expects a binary `order_id` and uses it directly as the AMQP message body. This example uses the dependency and local broker from [Getting Started](getting_started.md). Define this module in your application:

```elixir
defmodule MyApp.Receipts do
  @queue "receipts.pending"

  def setup(channel) do
    case AMQP.Queue.declare(channel, @queue, durable: true) do
      {:ok, _queue_info} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue(order_id) do
    publish = fn channel ->
      AMQP.Basic.publish(channel, "", @queue, order_id, persistent: true)
    end

    case AMQPChannelPool.checkout(MyApp.ReceiptPool, publish, []) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Add this child to your application's supervision tree. Each pool worker opens a connection and channel, then runs `setup/1`; recovery runs it again. The default exchange routes by queue name.

```elixir
{AMQPChannelPool,
 name: MyApp.ReceiptPool,
 connection: [host: "localhost"],
 pool_size: 4,
 channel_setup: &MyApp.Receipts.setup/1}
```

Start `iex -S mix` and enqueue a receipt:

```elixir
MyApp.Receipts.enqueue("order-42")
# => :ok
```

On success the caller gets `:ok`. If checkout or publishing returns an error, the caller gets `{:error, reason}`. See [Pool-Layer Failures](checkout_and_failure_semantics.md#pool-layer-failures) for checkout failure behavior.

## Enqueue from concurrent callers

With the receipt publisher and its supervised pool above running, paste this into IEx. Each task checks out its own channel for the duration of one publish. The four workers can serve up to four checkouts at once.

```elixir
["order-43", "order-44", "order-45"]
|> Task.async_stream(fn id -> {id, MyApp.Receipts.enqueue(id)} end, max_concurrency: 4)
|> Enum.to_list()
```

The first successful task yields `{:ok, {"order-43", :ok}}`. A returned error yields `{:ok, {"order-43", {:error, reason}}}`, so the caller can identify the affected order. The outer tuple belongs to the task. These tasks are linked to the caller.

## Route order events

Billing needs new orders. Audit needs every order event. A topic exchange lets one publisher serve both queues. Declare the topology when the pool opens a channel, then choose a routing key for each publish. `publish/2` expects a binary `order_id` and uses it directly as the AMQP message body.

```elixir
defmodule MyApp.OrderEvents do
  @exchange "orders.events"

  def setup(channel) do
    with :ok <- AMQP.Exchange.declare(channel, @exchange, :topic, durable: true),
         :ok <- bind_queue(channel, "billing.orders", "order.created") do
      bind_queue(channel, "audit.orders", "order.*")
    end
  end

  def publish(event, order_id) when event in [:created, :shipped] do
    routing_key = "order.#{event}"

    publish = fn channel ->
      AMQP.Basic.publish(channel, @exchange, routing_key, order_id, persistent: true)
    end

    case AMQPChannelPool.checkout(MyApp.OrderEventsPool, publish, []) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def publish(_event, _order_id), do: {:error, :unsupported_event}

  defp bind_queue(channel, queue, pattern) do
    case AMQP.Queue.declare(channel, queue, durable: true) do
      {:ok, _info} -> AMQP.Queue.bind(channel, queue, @exchange, routing_key: pattern)
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Add the named pool to your application's children. Startup and recovery both run `setup/1`.

```elixir
{AMQPChannelPool,
 name: MyApp.OrderEventsPool,
 connection: [host: "localhost"],
 pool_size: 2,
 channel_setup: &MyApp.OrderEvents.setup/1}
```

Try both events in IEx:

```elixir
MyApp.OrderEvents.publish(:created, "order-46")
# => :ok
MyApp.OrderEvents.publish(:shipped, "order-46")
# => :ok
MyApp.OrderEvents.publish(:cancelled, "order-46")
# => {:error, :unsupported_event}
```

| Queue | Binding | Routing keys from this publisher |
| --- | --- | --- |
| `billing.orders` | `order.created` | `order.created` |
| `audit.orders` | `order.*` | `order.created`, `order.shipped` |

### When the publisher needs broker confirmation

A publish call returning `:ok` reports success at the AMQP client. Enable
publisher confirms on each new channel and track outstanding publishes on that
channel to learn the broker's outcome. Routing is separate. RabbitMQ can
confirm an unroutable publish. With `mandatory: true`, handle the
`basic.return` that RabbitMQ sends before the acknowledgement when no queue
matches. A consumer reports its own processing separately through consumer
acknowledgements. [RabbitMQ publisher confirms and consumer acknowledgements](https://www.rabbitmq.com/docs/3.13/confirms)

After a confirm timeout, the publish outcome is unknown. Retrying can duplicate
a message the broker already accepted. If a checkout callback returns an error
tuple normally, the channel remains eligible for reuse even with a publish
outstanding. Give outstanding confirms an owner before sharing the channel
across callers. [RabbitMQ reliability guide](https://www.rabbitmq.com/docs/3.13/reliability#data-safety-on-the-publisher-side)
