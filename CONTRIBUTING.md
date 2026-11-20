# Contributing

## Workflow

1. Open a branch for your change.
2. Make the change in focused commits.
3. Run the local validation commands.
4. Open a pull request against the default branch.

## Validation

- `MIX_ENV=test mix deps.get`
- `mix dialyzer`
- `mix credo`
- `MIX_ENV=test mix coveralls.json`

### Verify the publishing quickstart

Follow [Getting Started](docs/guides/getting_started.md) in a fresh supervised
Mix app using the released Hex package and a disposable local RabbitMQ broker.
Start with an empty `demo.events` queue. After checkout returns `{:ok, :ok}`,
read and remove the message from the demo queue in IEx.

```elixir
AMQPChannelPool.checkout(MyApp.PublisherPool, fn channel ->
  AMQP.Basic.get(channel, "demo.events", no_ack: true)
end, [])
# => {:ok, {:ok, "hello", metadata}}
```

After a successful [recovery exercise](docs/guides/recovery_and_worker_lifecycle.md#try-recovery-locally),
repeat the readback and expect `"after recovery"`.

### Build a HexDocs preview

Build from a clean commit and set the source ref to that commit. Push the commit
to GitHub before sharing the preview so its View Source and README runtime links resolve.

```bash
AMQP_CHANNEL_POOL_DOCS_SOURCE_REF="$(git rev-parse HEAD)" mix docs --warnings-as-errors
```

Leave the override unset for release builds. View Source and the README runtime
links then use the package version tag.

### Runtime compatibility

When adding or removing an Elixir/OTP combination, update the CI matrix, the [Tested runtimes table](README.md#tested-runtimes), and the changelog together. Verify representative patch updates in CI and reassess the OTP floor when the AMQP client dependencies change.

## Review Expectations

- keep pull requests focused
- respond to review comments with follow-up commits or explicit reasoning
- prefer rebasing over merge commits
