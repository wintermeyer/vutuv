defmodule Vutuv.MixProject do
  use Mix.Project

  def project do
    [
      app: :vutuv,
      version: "7.343.1",
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
      # Resolves the real client IP from X-Forwarded-For behind the nginx
      # reverse proxy, so `conn.remote_ip` is the visitor's address instead of
      # the loopback proxy hop. The session fingerprint (security email) and the
      # rate limiter both key on it (issues #799, #837).
      {:remote_ip, "~> 1.2"},

      # Database
      {:ecto_sql, "~> 3.10"},
      {:phoenix_ecto, "~> 4.4"},
      {:postgrex, "~> 0.19"},

      # JSON
      {:jason, "~> 1.4"},

      # CSV parsing (LinkedIn data-export import); promotes the transitive
      # optional dep of :req to a direct one.
      {:nimble_csv, "~> 1.2"},

      # Email
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.0"},

      # HTTP client
      {:req, "~> 0.5"},

      # Phone numbers: parse/validate/format to E.164 and national formats
      # (Google's libphonenumber port). Used by Vutuv.Phone to render German
      # numbers in local format for `de` viewers while keeping E.164 in tel: links.
      {:ex_phone_number, "~> 0.4"},

      # CLDR territory data (compile-time, no runtime network → intranet-safe):
      # Vutuv.Cldr.Territory turns the ISO region of an international phone number
      # (from ex_phone_number) into a flag emoji shown next to the number (#892).
      {:ex_cldr, "~> 2.47"},
      {:ex_cldr_territories, "~> 2.12"},

      # IANA time zone database, compiled in from the bundled release (no
      # runtime network, so an air-gapped intranet install works): the
      # `Calendar.TimeZoneDatabase` behind `DateTime.shift_zone/2`, which
      # renders every member-facing timestamp in the viewer's own zone
      # (`Vutuv.ViewerClock`, issue #1502). The periodic updater
      # (`Tz.UpdatePeriodically`) is deliberately NOT supervised — a tzdata
      # release ships with the next vutuv release instead.
      {:tz, "~> 0.28"},

      # Passkey / WebAuthn (FIDO2) login: server-side verification of the
      # registration and authentication ceremonies (see Vutuv.Credentials). The
      # browser ceremony is plain JS in assets/js/webauthn.js. Pulls cbor/x509.
      {:wax_, "~> 0.7"},

      # Authenticator-app login codes (issue #912): RFC 6238 TOTP generation and
      # verification (see Vutuv.LoginCodes), plus the QR code the member scans
      # at enrolment, rendered server-side as SVG (works air-gapped).
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2"},

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
      # `npm ci` fetches the bundled JS deps (Milkdown) into assets/node_modules
      # so esbuild can bundle them; runs on `mix setup` and in the blue/green
      # deploy (scripts/deploy.sh calls `mix assets.setup`). node/npm come from
      # mise (.tool-versions); assets/node_modules is gitignored, the lockfile is
      # committed, so the build is reproducible.
      # The last step vendors @duckduckgo/autoconsent into the consent blocker
      # the screenshot browser injects (priv/chrome/autoconsent/README.md).
      # Copied rather than committed so `npm ci` keeps the CMP rules current;
      # a checkout that skipped it just captures consent dialogs as before.
      "assets.setup": [
        "cmd --cd assets npm ci",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "vutuv.autoconsent.vendor"
      ],
      # Two esbuild profiles: app.js and the on-demand markdown editor bundle
      # (see the esbuild block in config/config.exs for why they are split).
      # Both must run, or the composer loads a 404 and falls back to the plain
      # textarea.
      "assets.build": ["tailwind vutuv", "esbuild vutuv", "esbuild markdown_editor"],
      "assets.deploy": [
        "tailwind vutuv --minify",
        "esbuild vutuv --minify",
        "esbuild markdown_editor --minify",
        "phx.digest"
      ]
    ]
  end
end
