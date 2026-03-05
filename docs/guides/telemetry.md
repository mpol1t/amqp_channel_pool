# Telemetry

All events use the namespace:

```elixir
[:amqp_channel_pool, ...]
```

## Event Families

- `[:amqp_channel_pool, :checkout, :start | :stop | :exception]`
- `[:amqp_channel_pool, :worker, :init, :start | :stop | :exception]`
- `[:amqp_channel_pool, :worker, :recover, :start | :stop | :exception]`
- `[:amqp_channel_pool, :worker, :discard]`
- `[:amqp_channel_pool, :worker, :terminate]`

## Measurements

- start events: `%{system_time: integer()}`
- stop events: `%{duration: native_time_integer()}`
- exception events: `%{duration: native_time_integer()}`

## Stable Metadata Keys

- `:pool`
- `:worker_pid`
- `:worker_state`
- `:recovery_kind`
- `:reason`
- `:timeout`
- `:result`

Additional metadata keys can exist, but these keys remain stable.

## Result Classification

- checkout success: checkout `:stop`, `result: :ok`
- pool-layer checkout failure: checkout `:stop`, `result: :pool_error`
- callback failure (`raise`/`throw`/`exit`): checkout `:exception`, `result: :callback_exception`
- worker recovery failure: worker recover `:exception`, `result: :error`

Callback exceptions are intentionally separated from pool acquisition failures.

## Example Handler

```elixir
:telemetry.attach_many(
  "amqp-channel-pool-observer",
  [
    [:amqp_channel_pool, :checkout, :stop],
    [:amqp_channel_pool, :checkout, :exception],
    [:amqp_channel_pool, :worker, :recover, :exception]
  ],
  fn event, measurements, metadata, _config ->
    Logger.info("event=#{inspect(event)} measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}")
  end,
  nil
)
```
