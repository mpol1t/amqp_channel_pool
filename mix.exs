defmodule ElixirHexTemplate.MixProject do
  use Mix.Project
  @source_url "https://github.com/mpol1t/amqp_channel_pool"
  @version "0.3.0"

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
          "GitHub" => @source_url,
          "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
        }
      ],
      docs: &docs/0,
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.json": :test,
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
      {:amqp, "~> 4.3.0"},
      {:nimble_pool, "~> 1.1"},
      {:telemetry, "~> 1.2"},
      {:stream_data, "~> 1.4.0", only: :test},
      {:ex_doc, "~> 0.40.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.12.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18.3", only: [:test], runtime: false}
    ]
  end

  defp docs do
    source_ref = System.get_env("AMQP_CHANNEL_POOL_DOCS_SOURCE_REF", "v#{@version}")
    readme = docs_readme(source_ref)

    [
      main: "readme",
      source_ref: source_ref,
      source_url: @source_url,
      canonical: "https://hexdocs.pm/amqp_channel_pool",
      extras: [
        {readme, source: "README.md"},
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "docs/guides/getting_started.md",
        "docs/guides/publishing_examples.md",
        "docs/guides/configuration.md",
        "docs/guides/checkout_and_failure_semantics.md",
        "docs/guides/recovery_and_worker_lifecycle.md",
        "docs/guides/telemetry.md",
        "docs/guides/integration_testing.md"
      ],
      groups_for_extras: [
        Project: [readme, "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
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

  defp docs_readme(source_ref) do
    # HexDocs needs explicit URLs for files outside its generated pages.
    markdown =
      "README.md"
      |> File.read!()
      |> String.replace(
        ~r/\]\((\.github\/(?:workflows\/elixir\.yml|\.tool-versions))\)/,
        "](" <> @source_url <> "/blob/" <> source_ref <> "/\\1)"
      )

    path = Path.join(Mix.Project.manifest_path(), "README.md")
    File.write!(path, markdown)
    path
  end
end
