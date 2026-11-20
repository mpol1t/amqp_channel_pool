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

### Runtime compatibility

When adding or removing an Elixir/OTP combination, update the CI matrix, the [Tested runtimes table](README.md#tested-runtimes), and the changelog together. Verify representative patch updates in CI and reassess the OTP floor when the AMQP client dependencies change.

## Review Expectations

- keep pull requests focused
- respond to review comments with follow-up commits or explicit reasoning
- prefer rebasing over merge commits
