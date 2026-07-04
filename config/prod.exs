import Config

# Compile-time production config. Everything secret or environment-specific
# (database credentials, secret_key_base, public host, HTTP port, uploads
# directory) is set at boot in config/runtime.exs from the environment.
# Nothing in this file is a secret.

config :vutuv, VutuvWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  root: ".",
  version: Mix.Project.config()[:version],
  locales: ~w(en de)

config :logger, level: :error

# The SMTP mailer is configured at boot in config/runtime.exs (SMTP_RELAY,
# SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_TLS, SMTP_SSL), defaulting to
# the local loopback relay the vutuv.de production host runs.
