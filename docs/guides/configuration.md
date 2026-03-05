# Configuration

Pool startup requires explicit configuration and validates inputs eagerly.

## Required Options

- `:name` - pool process name (`atom`, `{:global, term}`, or `{:via, module, term}`)
- `:connection` - keyword list passed to `AMQP.Connection.open/1`

## Optional Options

- `:pool_size` - positive integer, defaults to `10`
- `:channel_setup` - callback `(channel -> :ok | {:error, reason})`
- `:id` - explicit child spec id for supervisor integration

## Unsupported Legacy Key

`opts` is rejected. Use `:connection`.

```elixir
# Invalid
{AMQPChannelPool, name: MyPool, opts: [host: "localhost"]}

# Valid
{AMQPChannelPool, name: MyPool, connection: [host: "localhost"]}
```

## Child Specification ID

Default child spec id is stable and derived from pool name:

```elixir
{AMQPChannelPool, pool_name}
```

Set `:id` to override when needed:

```elixir
{AMQPChannelPool, id: {:amqp_pool, :primary}, name: MyPool, connection: [host: "localhost"]}
```

## Channel Setup Callback

`channel_setup` runs after channel open during worker init and worker recovery.
It must return `:ok` or `{:error, reason}`.

```elixir
defp setup_channel(channel) do
  with {:ok, _} <- AMQP.Exchange.declare(channel, "events", :topic, durable: true),
       {:ok, _} <- AMQP.Queue.declare(channel, "events.primary", durable: true) do
    :ok
  else
    {:error, reason} -> {:error, reason}
  end
end
```
