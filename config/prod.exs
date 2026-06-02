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

config :vutuv, Vutuv.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: "127.0.0.1",
  port: 25,
  username: "",
  password: "",
  # Deliver in plaintext over the loopback to the local Postfix relay.
  # STARTTLS to 127.0.0.1 fails the handshake here ("wrong version number")
  # and silently drops the mail; TLS on loopback adds nothing, and Postfix
  # still uses TLS for its onward hops to the real MX.
  tls: :never,
  ssl: false,
  retries: 3
