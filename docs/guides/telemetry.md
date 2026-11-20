# Telemetry

All event names begin with `:amqp_channel_pool`.

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

| Outcome | Event | Metadata |
| --- | --- | --- |
| Callback returns normally, including `{:error, reason}` | `[:amqp_channel_pool, :checkout, :stop]` | `result: :ok` |
| Checkout returns a worker recovery error | `[:amqp_channel_pool, :checkout, :stop]` | `result: :pool_error`, with the error in `:reason` |
| The named pool is missing or checkout times out | `[:amqp_channel_pool, :checkout, :exception]` | `result: :pool_checkout_exception`, `kind: :exit`, and the exit reason in `:reason` |
| Callback raises, throws, or exits | `[:amqp_channel_pool, :checkout, :exception]` | `result: :callback_exception`, with `:kind` and `:reason` |
| Worker recovery fails | `[:amqp_channel_pool, :worker, :recover, :exception]` | `result: :error` |

Both checkout events include `:pool` and `:timeout`. When checkout exits while
acquiring a worker, `:worker_pid` and `:worker_state` are `nil`. Invalid
checkout options fail validation before checkout telemetry starts.

## Example Handler

To log checkout duration, define a handler and attach it once at application startup.

```elixir
defmodule MyApp.PoolLogger do
  require Logger

  def attach do
    :telemetry.attach(
      "pool-checkout-duration",
      [:amqp_channel_pool, :checkout, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(_event, %{duration: duration}, %{pool: pool, result: result}, _config) do
    elapsed_us = System.convert_time_unit(duration, :native, :microsecond)
    Logger.debug(fn -> "pool=#{inspect(pool)} checkout=#{result} duration_us=#{elapsed_us}" end)
  end
end

:ok = MyApp.PoolLogger.attach()
```
