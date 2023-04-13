defmodule CarReq.MixProject do
  use Mix.Project

  @name "CarReq"
  @source_url "https://github.com/carsdotcom/car_req"
  @version "0.1.1"

  def project do
    [
      app: :car_req,
      elixirc_paths: elixirc_paths(Mix.env()),
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      name: @name
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/fixtures"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false, optional: true, app: false},
      # HTTP Client deps
      {:nimble_options, "~> 0.4"},
      {:req, "~> 0.3"},
      {:req_fuse, "~> 0.2"},
      # telemetry is a transient dependency through req (finch)
      # but CarReq emits telemetry, so we'll be explicit about it as a dependency.
      {:telemetry, ">= 0.0.0"}

      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  defp docs do
    [
      # logo: "assets/fuse.png",
      source_ref: "v#{@version}",
      source_url: @source_url,
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end
end
