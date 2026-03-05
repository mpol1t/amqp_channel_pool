defmodule ElixirHexTemplate.MixProject do
  use Mix.Project
  @version "0.2.1"

  def project do
    [
      app: :amqp_channel_pool,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "A lightweight Elixir library for managing a pool of AMQP channels using NimblePool.",
      package: [
        licenses: ["Apache-2.0"],
        links: %{
          "GitHub" => "https://github.com/mpol1t/amqp_channel_pool",
          "Changelog" => "https://github.com/mpol1t/amqp_channel_pool/blob/main/CHANGELOG.md"
        }
      ],
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :telemetry]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amqp, "~> 4.1.0"},
      {:nimble_pool, "~> 1.1"},
      {:telemetry, "~> 1.2"},
      {:stream_data, "~> 1.2.0", only: :test},
      {:ex_doc, "~> 0.40.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18.3", only: [:test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: "https://github.com/mpol1t/amqp_channel_pool",
      canonical: "https://hexdocs.pm/amqp_channel_pool",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "docs/guides/getting_started.md",
        "docs/guides/configuration.md",
        "docs/guides/checkout_and_failure_semantics.md",
        "docs/guides/recovery_and_worker_lifecycle.md",
        "docs/guides/telemetry.md",
        "docs/guides/integration_testing.md"
      ],
      groups_for_extras: [
        Project: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
        Guides: ~r/docs\/guides\/.*/
      ],
      groups_for_modules: [
        PublicAPI: [AMQPChannelPool],
        Internals: [
          AMQPChannelPool.AMQPClient,
          AMQPChannelPool.Telemetry,
          AMQPChannelPool.Worker
        ]
      ],
      skip_undefined_reference_warnings_on: []
    ]
  end
end
