# Integration Testing

Integration tests are tagged with `:integration` and require RabbitMQ.

## Unit Suite (Default)

```bash
mix test
```

Default suite excludes integration-tagged tests.

## Integration-Only Suite With Docker

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

## Determinism Guidance

Integration assertions should use observable synchronization, for example:

- process liveness checks
- bounded eventual assertions
- explicit wait conditions tied to broker-visible state

Avoid timing-lucky immediate assumptions after channel/connection closure.
