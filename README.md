[![codecov](https://codecov.io/gh/mpolit/amqp_channel_pool/graph/badge.svg?token=<token>)](https://codecov.io/gh/mpolit/amqp_channel_pool)
[![Hex.pm](https://img.shields.io/hexpm/v/amqp_channel_pool.svg)](https://hex.pm/packages/amqp_channel_pool)
[![License](https://img.shields.io/github/license/mpolit/amqp_channel_pool.svg)](https://github.com/mpolit/amqp_channel_pool/blob/main/LICENSE)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/amqp_channel_pool)
[![Build Status](https://github.com/mpolit/amqp_channel_pool/actions/workflows/elixir.yml/badge.svg)](https://github.com/mpolit/amqp_channel_pool/actions)
[![Elixir Version](https://img.shields.io/badge/elixir-~%3E%201.16-purple.svg)](https://elixir-lang.org/)

# AMQPChannelPool

A lightweight Elixir library for managing a pool of AMQP channels using NimblePool. It simplifies connection handling and channel reuse, providing an easy-to-use API for publishing messages and interacting with RabbitMQ efficiently.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Running Tests](#running-tests)
- [Running Dialyzer](#running-dialyzer)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Connection Pooling**: Efficiently manages AMQP connections and channels using NimblePool.
- **Simple API**: Checkout and reuse channels with ease.
- **Customizable**: Configure connection options and pool size based on your application's needs.
- **Lightweight**: Minimal dependencies and easy integration.

## Installation

Add `amqp_channel_pool` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:amqp_channel_pool, "~> 0.1.1"}
  ]
end
```

Then fetch the dependencies:

```bash
mix deps.get
```

## Configuration

Customize the behavior of the pool using the options described in the [AMQP.Connection documentation](https://hexdocs.pm/amqp/AMQP.Connection.html#open/1).

## Usage

### Starting the Pool

Include `AMQPChannelPool` in your supervision tree:

```elixir
children = [
  {AMQPChannelPool, [
    opts: [
      host: "localhost",
      port: 5672,
      username: "guest",
      password: "guest"
    ],
    pool_size: 5
  ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Publishing Messages

Check out a channel from the pool and publish a message:

```elixir
AMQPChannelPool.checkout!(fn channel ->
  AMQP.Basic.publish(channel, "exchange_name", "routing_key", "message_payload")
end)
```

## Running Tests

To ensure the project functions as expected, run tests:

```bash
mix test
```

## Running Dialyzer

Run Dialyzer for static analysis:

```bash
mix dialyzer --plt
mix dialyzer
```

## Contributing

Contributions are welcome! Please see the [CONTRIBUTING](CONTRIBUTING.md) file for details.
## License

This project is licensed under the Apache License, Version 2.0 - see the [LICENSE](LICENSE) file for details.