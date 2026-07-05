defmodule Vutuv.Cldr do
  @moduledoc """
  CLDR backend, scoped to territory data.

  Its only job today is turning the ISO region code of an international phone
  number (resolved by `ex_phone_number`) into a flag emoji shown next to the
  number on the profile (issue #892) — see `Vutuv.Phone.country_flag/2`.

  The CLDR data for the configured locales is **compiled in** from the bundled
  repository, so no runtime network access is ever needed. That keeps it safe
  for air-gapped intranet installs, per the installability rule.
  """
  use Cldr,
    locales: ["en", "de"],
    default_locale: "en",
    providers: [Cldr.Territory]
end
