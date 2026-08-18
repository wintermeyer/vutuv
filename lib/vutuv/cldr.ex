defmodule Vutuv.Cldr do
  @moduledoc """
  CLDR backend, scoped to territory data.

  Its only job today is turning the ISO region code of an international phone
  number (resolved by `ex_phone_number`) into a flag emoji shown next to the
  number on the profile (issue #892) — see `Vutuv.Phone.country_flag/2`.

  The CLDR data for the configured locales is **compiled in**, so no network
  access is needed at build time or at runtime; that keeps air-gapped intranet
  installs safe, per the installability rule, and since issue #1545 the
  release build too. The hex package bundles `en` and `und` but downloads
  other locales from raw.githubusercontent.com during compilation — a GitHub
  incident once blocked the production build that way. The `otp_app` option
  points ex_cldr's locale lookup at our own `priv/cldr/locales/`, where the
  non-bundled `de.json` is committed (bundled locales fall back to the
  package's copies). `Vutuv.CldrLocaleBundleTest` fails the build when a
  configured locale would need a download. To add or refresh a locale, compile
  once with network access — ex_cldr writes the file into
  `priv/cldr/locales/` — and commit it.
  """
  use Cldr,
    otp_app: :vutuv,
    locales: ["en", "de"],
    default_locale: "en",
    providers: [Cldr.Territory]
end
