# Checkout and Failure Semantics

## API Shape

- `checkout(pool_name, fun, opts) :: {:ok, result} | {:error, reason}`
- `checkout!(pool_name, fun, opts) :: result | no_return`

The pool name is always explicit.

## Pool-Layer Failures

Invalid options and worker recovery failures return `{:error, exception}` from
`checkout/3`. The bang variant raises that exception. Both functions exit the
caller if the named pool is missing or the wait for a channel times out.
When worker recovery fails, the pool discards the failed worker and replaces it.

## Callback return values

If a callback returns `{:error, reason}` normally, `checkout/3` returns
`{:ok, {:error, reason}}`. The worker checks the channel back in and the channel
remains eligible for reuse, subject to the usual liveness checks.

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

When a callback returns normally, borrower code is responsible for keeping channel state valid.
If callback logic leaves channel state uncertain, fail the callback so the worker is
discarded.

## Checkout Options

- `:timeout` - non-negative integer, defaults to `5_000`
