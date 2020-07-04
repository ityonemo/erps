defmodule Erps.MixProject do
  use Mix.Project

  def project do
    [
      app: :erps,
      version: "0.6.1",
      elixir: "~> 1.10",
      description: "TLS-based remote protocol (call/cast) server",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
      package: package(),
      source_url: "https://github.com/ityonemo/erps/",
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  defp deps, do: [
    # static analysis and testing tools
    {:credo, "~> 1.2", only: [:test, :dev], runtime: false},
    {:dialyxir, "~> 0.5.1", only: :dev, runtime: false},
    {:ex_doc, "~> 0.20.2", only: :dev, runtime: false},
    {:excoveralls, "~> 0.11.1", only: :test},
    {:multiverses, "~> 0.6.0", runtime: false},

    # abstracts services which are connections
    {:connection, "~> 1.0"},
    # abstracts TLS and TCP into a single interface
    {:transport, "~> 0.1.0"},

    # for making testing TLS easier.
    {:x509, "~> 0.8.0", only: [:dev, :test]},
    {:plug_crypto, "~> 1.1.2"},

    # for simplifying tests
    {:net_address, "~> 0.2.1", only: :test}
  ]

  defp elixirc_paths(:test), do: ["lib", "test/_support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package, do: [
    name: "erps",
    licenses: ["MIT"],
    files: ~w(lib mix.exs README* LICENSE* VERSIONS* diagram.svg),
    links: %{"GitHub" => "https://github.com/ityonemo/erps"}
  ]
end
