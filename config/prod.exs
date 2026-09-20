import Config

# Compile-time production config. Everything secret or environment-specific
# (database credentials, secret_key_base, public host, HTTP port, uploads
# directory) is set at boot in config/runtime.exs from the environment.
# Nothing in this file is a secret.

# `locales:` is deliberately NOT repeated here. `config.exs` imports this file
# last and deep-merges onto the same Endpoint keyword list, so the list it sets
# already reaches production — measured with `Config.Reader.read!(env: :prod)`,
# which answers the same four locales with and without a copy here. The copy
# was not merely redundant: it is the one place `Vutuv.SiteLocalesChokepointTest`
# cannot see (it greps `lib/**`), so a list that fell behind would have served
# production fewer languages than the suite ever tested.
config :vutuv, VutuvWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  root: "."

# Quiet by default, and `LOG_LEVEL` in config/runtime.exs raises the bar for a
# boot. Anything an operator must be able to read while chasing a problem is
# logged at `:error` for that reason (see `VutuvWeb.OauthController`).
#
# This line is the global level, not the whole truth: `Vutuv.Application`
# raises five modules to `:info` at boot (the deliverability alarms and the AI
# image scan — see `ops_log_modules/0`, flag `:ops_log_visibility`), so a
# running node is louder than this file. Per-module levels are invisible to
# `Logger.level/0` and to `:logger`'s primary config, which is how a journal
# full of `[warning] image_scan …` came to look like a mystery (issue #1575);
# the node now names its own overrides once per boot — `grep logger_override`.
config :logger, level: :error

# The SMTP mailer is configured at boot in config/runtime.exs (SMTP_RELAY,
# SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_TLS, SMTP_SSL), defaulting to
# the local loopback relay the vutuv.de production host runs.
