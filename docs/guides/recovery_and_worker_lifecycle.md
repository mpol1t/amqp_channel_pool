# Recovery and Worker Lifecycle

## Try recovery locally

After [Getting Started](getting_started.md), the local pool has one worker and
the demo queue exists. Use a disposable local pool for this exercise. Monitor
the borrowed channel before closing it and wait for that process to exit.
The next checkout can then recover the worker and publish on a fresh channel.

```elixir
close_channel = fn channel ->
  pid = channel.pid
  ref = Process.monitor(pid)

  try do
    case AMQP.Channel.close(channel) do
      :ok ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> {:error, :channel_close_timeout}
        end

      {:error, reason} ->
        {:error, {:channel_close_failed, reason}}
    end
  catch
    :exit, reason -> {:error, {:channel_close_failed, reason}}
  after
    Process.demonitor(ref, [:flush])
  end
end

case AMQPChannelPool.checkout(MyApp.PublisherPool, close_channel, []) do
  {:ok, :ok} ->
    AMQPChannelPool.checkout(MyApp.PublisherPool, fn channel ->
      AMQP.Basic.publish(channel, "", "demo.events", "after recovery")
    end, [])

  {:ok, {:error, reason}} ->
    {:error, reason}

  {:error, reason} ->
    {:error, reason}
end
# => {:ok, :ok}
```

If the close returns an error or the wait times out, the example skips the
publish. Stop the exercise and leave the pool alone. A callback that returns
an error normally can leave the worker eligible for reuse, even when the
channel's state is uncertain. Restart the disposable demo pool before any
further checkout or publish. Exit IEx with `System.stop()`, then start a new
`iex -S mix` session so your application supervisor starts a fresh pool.

The application issued this second publish. Channel recovery does not replay earlier messages. If you configured `:channel_setup`, the pool runs it on the new channel before the callback starts. To observe recovery in your application, see [Telemetry](telemetry.md).

## Lifecycle states

Workers use explicit lifecycle states:

- `:starting`
- `:ready`
- `:stale`
- `:recovering`
- `:closing`

## Stale Detection

Workers are marked stale through:

- monitor `DOWN` on connection process
- monitor `DOWN` on channel process
- checkout-time liveness validation

Stale workers are never silently handed out.

## Recovery Behavior

On checkout of a stale worker, the pool performs one immediate recovery attempt:

1. close existing runtime resources (best effort)
2. open new connection
3. open new channel
4. run `:channel_setup`
5. install monitors and transition to `:ready`

No retry loops or backoff logic are applied inside the library.

## Recovery Failure

If recovery fails, checkout fails with a typed pool-layer error:

- `%AMQPChannelPool.Worker.RecoveryError{}`

The failed worker is discarded and replaced by the pool.

## Startup Failure Cleanup

Worker startup failure closes partially opened resources best effort.
Pool startup fails deterministically instead of leaving half-initialized workers.
