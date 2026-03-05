[![codecov](https://codecov.io/gh/mpol1t/amqp_channel_pool/graph/badge.svg?token=SguSOIUQFy)](https://codecov.io/gh/mpol1t/amqp_channel_pool)
[![Hex.pm](https://img.shields.io/hexpm/v/amqp_channel_pool.svg)](https://hex.pm/packages/amqp_channel_pool)
[![License](https://img.shields.io/github/license/mpol1t/amqp_channel_pool.svg)](https://github.com/mpol1t/amqp_channel_pool/blob/main/LICENSE)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/amqp_channel_pool)
[![Build Status](https://github.com/mpol1t/amqp_channel_pool/actions/workflows/elixir.yml/badge.svg)](https://github.com/mpol1t/amqp_channel_pool/actions)
[![Elixir Version](https://img.shields.io/badge/elixir-~%3E%201.16-purple.svg)](https://elixir-lang.org/)

# AMQPChannelPool

A lightweight Elixir library for managing named AMQP channel pools with NimblePool.

## Installation

Add `amqp_channel_pool` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:amqp_channel_pool, "~> 0.2.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Configuration

Pool startup requires:

- `:name`
- `:connection`

Optional startup options:

- `:pool_size` with a default of `10`
- `:channel_setup` to configure a freshly opened channel before it enters service
- `:id` to override the default child specification id

The `:connection` value is passed to `AMQP.Connection.open/1`.
The `:opts` key is not supported.

## Usage

### Starting named pools

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
   pool_size: 5,
   channel_setup: &declare_topology/1},
  {AMQPChannelPool,
   name: MyApp.SecondaryPool,
   connection: [
     host: "localhost",
     port: 5672,
     username: "guest",
     password: "guest"
   ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Checking out a channel

```elixir
{:ok, :ok} =
  AMQPChannelPool.checkout(MyApp.PrimaryPool, fn channel ->
    AMQP.Queue.declare(channel, "service.health", durable: true)
  end, timeout: 5_000)

AMQPChannelPool.checkout!(MyApp.SecondaryPool, fn channel ->
  AMQP.Queue.declare(channel, "service.audit", durable: true)
end, timeout: 5_000)
```

### Stopping a named pool

```elixir
:ok = AMQPChannelPool.stop(MyApp.PrimaryPool)
```

### Channel setup callback

```elixir
defp declare_topology(channel) do
  with {:ok, _} <- AMQP.Exchange.declare(channel, "service.events", :topic, durable: true),
       {:ok, _} <- AMQP.Queue.declare(channel, "service.events.primary", durable: true) do
    :ok
  else
    {:error, reason} -> {:error, reason}
  end
end
```

`channel_setup` can enable confirm mode and topology, but confirm mode alone is not
sufficient to guarantee end-to-end reliable delivery.

### Stale worker recovery

Workers are monitored for connection and channel process exits. If a worker is stale at checkout
time, the pool performs one immediate recovery attempt by reopening the connection and channel,
reapplying `:channel_setup`, and reinstalling monitors. If recovery fails, checkout returns a
pool-layer error and the failed worker is discarded for replacement.

### Borrower failure semantics

`checkout/3` and `checkout!/3` preserve normal Elixir callback failure behavior:

- `raise` re-raises to the caller
- `exit` exits the caller
- `throw` throws to the caller

These abnormal callback outcomes are not converted into pool-layer `{:error, reason}` tuples.
The borrowed worker is discarded and replaced before reuse to avoid channel contamination.

Borrowers are responsible for channel hygiene when callbacks succeed. If callback code may
leave channel state uncertain, fail the callback so the worker is discarded.

### Telemetry

Event namespace:

- `[:amqp_channel_pool, ...]`

Event families:

- `[:amqp_channel_pool, :checkout, :start | :stop | :exception]`
- `[:amqp_channel_pool, :worker, :init, :start | :stop | :exception]`
- `[:amqp_channel_pool, :worker, :recover, :start | :stop | :exception]`
- `[:amqp_channel_pool, :worker, :discard]`
- `[:amqp_channel_pool, :worker, :terminate]`

Measurements:

- start events include `system_time`
- stop and exception events include `duration`

Stable metadata keys:

- `pool`
- `worker_pid`
- `worker_state`
- `recovery_kind`
- `reason`
- `timeout`
- `result`

Failure semantics in telemetry:

- checkout callback failures (`raise`/`throw`/`exit`) emit checkout `:exception` with `result: :callback_exception`
- pool-layer checkout failures that return `{:error, reason}` emit checkout `:stop` with `result: :pool_error`
- worker recovery failures emit worker recover `:exception`

### Pool Boundary

The pool library is intentionally generic infrastructure. It owns:

- channel pool lifecycle and checkout behavior
- stale detection, one-shot recovery, and worker replacement
- pool-layer telemetry and failure reporting

Publisher applications own:

- message routing policy
- serialization and headers
- confirm waiting/ack handling
- retry and idempotency strategy

The pool does not provide publish convenience APIs and does not guarantee delivery
semantics on behalf of the application.

## Running Tests

```bash
mix test
```

Unit tests run by default. Integration tests are tagged with `:integration` and
are excluded unless `RUN_INTEGRATION=true` is set.

### Running Integration Tests With RabbitMQ

```bash
docker network create amqp-channel-pool-test-net
docker run -d --rm --name amqp-test-rabbit --network amqp-channel-pool-test-net rabbitmq:3.13-management

docker run --rm --network amqp-channel-pool-test-net \
  -e RUN_INTEGRATION=true \
  -e AMQP_TEST_HOST=amqp-test-rabbit \
  -e AMQP_TEST_PORT=5672 \
  -v "$(pwd)":/app -w /app elixir:1.16 \
  sh -lc 'mix local.hex --force && mix local.rebar --force && mix deps.get && mix test --only integration'

docker stop amqp-test-rabbit
docker network rm amqp-channel-pool-test-net
```

## Running Dialyzer

```bash
mix dialyzer --plt
mix dialyzer
```

## Contributing

Contributions are welcome. See [CONTRIBUTING](CONTRIBUTING.md).

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
