defmodule Vutuv.MixProject do
  use Mix.Project

  def project do
    [
      app: :vutuv,
      version: "7.12.1",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # Lets the dev code reloader coordinate with concurrent `mix` invocations
      # (without it, hot reload crashes on a Mix.Sync.Lock conflict whenever
      # another mix process compiles — e.g. `mix test` in a second terminal).
      listeners: [Phoenix.CodeReloader]
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
      # AI-assisted dev tooling: mounts an MCP endpoint at /tidewave/mcp in
      # the dev server so coding agents can inspect the running app.
      {:tidewave, "~> 0.5", only: :dev},
      # LiveView's test helpers (`Phoenix.LiveViewTest`) parse the rendered DOM
      # with lazy_html; required for the connected-mount assertions.
      {:lazy_html, ">= 0.1.0", only: :test},
      # Chat-message markdown: Earmark renders, HtmlSanitizeEx strips anything
      # dangerous (user input must never reach the DOM unsanitized).
      {:earmark, "~> 1.4"},
      {:html_sanitize_ex, "~> 1.4"},
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

      # Phone numbers: parse/validate/format to E.164 and national formats
      # (Google's libphonenumber port). Used by Vutuv.Phone to render German
      # numbers in local format for `de` viewers while keeping E.164 in tel: links.
      {:ex_phone_number, "~> 0.4"},

      # Passkey / WebAuthn (FIDO2) login: server-side verification of the
      # registration and authentication ceremonies (see Vutuv.Credentials). The
      # browser ceremony is plain JS in assets/js/webauthn.js. Pulls cbor/x509.
      {:wax_, "~> 0.7"},

      # File uploads / image processing (libvips via vix)
      {:image, "~> 0.67"},

      # i18n
      {:gettext, "~> 1.0"},

      # Testing
      {:ex_machina, "~> 2.7", only: :test},

      # PubSub
      {:phoenix_pubsub, "~> 2.1"},

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
