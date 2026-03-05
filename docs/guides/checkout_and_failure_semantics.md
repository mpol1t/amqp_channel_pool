# Checkout and Failure Semantics

## API Shape

- `checkout(pool_name, fun, opts) :: {:ok, result} | {:error, reason}`
- `checkout!(pool_name, fun, opts) :: result | no_return`

The pool name is always explicit.

## Pool-Layer Failures

Pool-layer failures are returned as `{:error, reason}` from `checkout/3`, and raised by
`checkout!/3`.

Recovery/setup failures are surfaced as `%AMQPChannelPool.Worker.RecoveryError{}`.

## Callback Failure Propagation

Callback failures are not converted into pool errors:

- `raise` re-raises
- `exit` exits caller
- `throw` throws to caller

This preserves standard Elixir semantics and avoids misclassifying application failures as
pool infrastructure failures.

## Borrower Hygiene Rule

When a callback fails abnormally (`raise`, `exit`, `throw`), the worker is discarded and
replaced before reuse.

For successful callbacks, borrower code is responsible for keeping channel state valid.
If callback logic leaves channel state uncertain, fail the callback so the worker is
discarded.

## Checkout Options

- `:timeout` - non-negative integer, defaults to `5_000`
