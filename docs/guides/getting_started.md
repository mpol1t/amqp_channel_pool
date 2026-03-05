# Getting Started

`amqp_channel_pool` provides named AMQP channel pools backed by `NimblePool`.

## Installation

Add the dependency in `mix.exs`:

```elixir
def deps do
  [
    {:amqp_channel_pool, "~> 0.2.1"}
  ]
end
```

Install dependencies:

```bash
mix deps.get
```

## Start a Pool

```elixir
children = [
  {AMQPChannelPool,
   name: MyApp.PrimaryPool,
   connection: [
     host: "localhost",
     port: 5672,
     username: "guest",
     password: "guest"
   ],
   pool_size: 10}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Checkout a Channel

```elixir
{:ok, :ok} =
  AMQPChannelPool.checkout(MyApp.PrimaryPool, fn channel ->
    AMQP.Queue.declare(channel, "service.health", durable: true)
  end, timeout: 5_000)
```

Use `checkout!/3` when you want pool-layer failures to raise:

```elixir
AMQPChannelPool.checkout!(MyApp.PrimaryPool, fn channel ->
  AMQP.Queue.declare(channel, "service.audit", durable: true)
end, timeout: 5_000)
```

## Stop a Pool

```elixir
:ok = AMQPChannelPool.stop(MyApp.PrimaryPool)
```

## Next Guides

- [Configuration](configuration.md)
- [Checkout and Failure Semantics](checkout_and_failure_semantics.md)
- [Recovery and Worker Lifecycle](recovery_and_worker_lifecycle.md)
- [Telemetry](telemetry.md)
