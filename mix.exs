defmodule ElixirHexTemplate.MixProject do
  use Mix.Project

  def project do
    [
      app: :amqp_channel_pool,
      version: "0.1.1",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      #      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "A lightweight Elixir library for managing a pool of AMQP channels using NimblePool.",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/mpol1t/amqp_channel_pool"}
      ],
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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amqp, "~> 4.0.0"},
      {:nimble_pool, "~> 1.1"},
      {:stream_data, "~> 1.2.0", only: :test},
      {:ex_doc, "~> 0.38.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.4.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18.3", only: [:test], runtime: false}
    ]
  end
end
