defmodule Vutuv.MixProject do
  use Mix.Project

  def project do
    [
      app: :vutuv,
      version: "5.0.0",
      elixir: "~> 1.20-rc",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Vutuv.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Run `mix precommit` in the test environment so its `test` step is happy.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_html_helpers, "~> 1.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.4", only: :dev},
      {:bandit, "~> 1.0"},

      # Database
      {:ecto_sql, "~> 3.10"},
      {:phoenix_ecto, "~> 4.4"},
      {:postgrex, "~> 0.19"},

      # JSON
      {:jason, "~> 1.4"},

      # Email
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.0"},

      # HTTP client
      {:req, "~> 0.5"},

      # File uploads / image processing (libvips via vix)
      {:image, "~> 0.67"},

      # i18n
      {:gettext, "~> 1.0"},

      # Testing
      {:ex_machina, "~> 2.7", only: :test},

      # PubSub
      {:phoenix_pubsub, "~> 2.1"},

      # Utilities

      # Asset pipeline
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "test"
      ],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind vutuv", "esbuild vutuv"],
      "assets.deploy": [
        "tailwind vutuv --minify",
        "esbuild vutuv --minify",
        "phx.digest"
      ]
    ]
  end
end
