# Recovery and Worker Lifecycle

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
