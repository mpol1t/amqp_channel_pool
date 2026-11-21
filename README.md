[![codecov](https://codecov.io/gh/mpol1t/amqp_channel_pool/graph/badge.svg?token=SguSOIUQFy)](https://codecov.io/gh/mpol1t/amqp_channel_pool)
[![Hex.pm](https://img.shields.io/hexpm/v/amqp_channel_pool.svg)](https://hex.pm/packages/amqp_channel_pool)
[![License](https://img.shields.io/github/license/mpol1t/amqp_channel_pool.svg)](https://github.com/mpol1t/amqp_channel_pool/blob/main/LICENSE)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/amqp_channel_pool)
[![Build Status](https://github.com/mpol1t/amqp_channel_pool/actions/workflows/elixir.yml/badge.svg?branch=main)](https://github.com/mpol1t/amqp_channel_pool/actions/workflows/elixir.yml)

# AMQPChannelPool

Use a named channel pool when several processes in your Elixir application publish to RabbitMQ. Each checkout borrows a channel for the duration of a callback, then returns it to the pool for reuse. Your application controls message routing, publisher confirms, and retries.

## Publish your first message

With RabbitMQ running on `localhost:5672` and the default local credentials, add `{:amqp_channel_pool, "~> 0.2.1"}` to your Mix dependencies and run `mix deps.get`. Add this child to your application’s supervision tree:

```elixir
{AMQPChannelPool, name: MyApp.PublisherPool, connection: [host: "localhost"], pool_size: 2}
```

Start `iex -S mix`. Declare a queue and publish to it in one checkout. RabbitMQ’s default exchange (`""`) routes the message by queue name.

```elixir
AMQPChannelPool.checkout(MyApp.PublisherPool, fn channel ->
  case AMQP.Queue.declare(channel, "demo.events") do
    {:ok, _queue} -> AMQP.Basic.publish(channel, "", "demo.events", "hello")
    {:error, reason} -> {:error, reason}
  end
end, [])
# => {:ok, :ok}
```

The outer `{:ok, result}` means the callback returned normally. The inner `:ok` means the publish call succeeded. Broker confirmation and consumer processing are separate steps. If the declaration or publish call returns an error, the result is `{:ok, {:error, reason}}`.

## Share the pool between callers

With the same queue and pool, two tasks can publish concurrently. Each task borrows a channel for its own publish and returns the checkout result alongside its order ID.

```elixir
["order-42", "order-43"]
|> Task.async_stream(fn id ->
  result = AMQPChannelPool.checkout(MyApp.PublisherPool, fn channel ->
    AMQP.Basic.publish(channel, "", "demo.events", id)
  end, [])

  {id, result}
end, max_concurrency: 2)
|> Enum.to_list()
# => [{:ok, {"order-42", {:ok, :ok}}}, {:ok, {"order-43", {:ok, :ok}}}]
```

## Where to go next

| Level | Example | What it adds |
| --- | --- | --- |
| First checkout | [Getting Started](docs/guides/getting_started.md) | Walk through the supervised application setup step by step. |
| Application | [Enqueue a receipt](docs/guides/publishing_examples.md#enqueue-a-background-job) | Prepare channels on startup and give callers a function with explicit error results. |
| Concurrent callers | [Publish a batch](docs/guides/publishing_examples.md#enqueue-from-concurrent-callers) | Share a bounded pool and associate each result with its order. |
| Event routing | [Route order events](docs/guides/publishing_examples.md#route-order-events) | Use topic bindings to send different events to billing and audit queues. |
| Operations | [Recover a closed channel](docs/guides/recovery_and_worker_lifecycle.md#try-recovery-locally) | Observe the next checkout recover and send another message. |

## Reference

- [Configuration](docs/guides/configuration.md)
- [Checkout and Failure Semantics](docs/guides/checkout_and_failure_semantics.md)
- [Recovery and Worker Lifecycle](docs/guides/recovery_and_worker_lifecycle.md)
- [Telemetry](docs/guides/telemetry.md)

## Tested runtimes

These are the Elixir and Erlang/OTP runtimes for the application connecting to RabbitMQ. For a new application, the primary tested pair is **Elixir 1.20 / OTP 29**.

| Elixir | Tested OTP majors |
| --- | --- |
| 1.16 | 26 |
| 1.17 | 26, 27 |
| 1.18 | 26, 27 |
| 1.19 | 26, 27, 28 |
| 1.20 | 27, 28, 29 |

For each combination, CI runs the unit and RabbitMQ integration suites with locked dependencies on one representative patch pair specified in the [CI workflow](.github/workflows/elixir.yml) and [primary runtime pins](.github/.tool-versions).

## Running Tests

Run unit tests with `mix test` and static analysis with `mix dialyzer`. For the broker-backed suite, see [Integration Testing](docs/guides/integration_testing.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING](CONTRIBUTING.md).

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
