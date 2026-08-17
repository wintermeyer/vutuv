defmodule Vutuv.DateRegions do
  @moduledoc """
  How a member wants dates and times written: `31.12.2026, 14:30`,
  `31/12/2026, 14:30`, `12/31/2026, 2:30 PM` or `2026-12-31, 14:30`.

  Four shapes, not two hundred. The interface language (`users.locale`) says
  nothing about this — an English-speaking member in Berlin wants the 24-hour
  clock, a German-speaking one in Chicago does not — which is why it is a
  field of its own (issue #1502) rather than something read off the locale.

  Each entry is a *format*, labelled with the regions that write dates that
  way; `from_accept_language/1` guesses one from the browser's language tag so
  a new account starts right, and the member overrides it on
  /settings/preferences. Because it is only ever a guess with an override
  behind it, the country table below claims the regions we are sure of and
  leaves the rest to the installation default rather than inventing a rule for
  every territory — that is what CLDR is for, and a menu of four is what a
  member can actually choose from.
  """

  # The sample rendered beside every option, so the choice is made by looking
  # rather than by decoding a pattern.
  @sample ~N[2026-12-31 14:30:00]

  @regions %{
    "DE" => %{
      date: "%d.%m.%Y",
      short_date: "%d.%m.%y",
      day_month: "%d.%m.",
      time: "%H:%M",
      seconds: "%H:%M:%S",
      clock: :h24
    },
    "GB" => %{
      date: "%d/%m/%Y",
      short_date: "%d/%m/%y",
      day_month: "%d/%m",
      time: "%H:%M",
      seconds: "%H:%M:%S",
      clock: :h24
    },
    "US" => %{
      date: "%-m/%-d/%Y",
      short_date: "%-m/%-d/%y",
      day_month: "%-m/%-d",
      time: "%-I:%M %p",
      seconds: "%-I:%M:%S %p",
      clock: :h12
    },
    "ISO" => %{
      date: "%Y-%m-%d",
      short_date: "%Y-%m-%d",
      day_month: "%m-%d",
      time: "%H:%M",
      seconds: "%H:%M:%S",
      clock: :h24
    }
  }

  # The parts a region defines. `day_month` is the year-dropping form for a
  # date the reader already knows the year of (a birthday, a same-year activity
  # stamp); `seconds` is a time that pins an event down to the second.
  @parts ~w(date short_date day_month time seconds)a

  # Display order: the site's own shape first, then the two English-speaking
  # ones, then the international standard.
  @keys ~w(DE GB US ISO)

  # The region subtag of an `Accept-Language` tag -> the shape that region
  # writes dates in. Only entries we are confident about; anything missing
  # falls through to the installation default, which a member can override.
  @by_country %{
    "US" => "US",
    "PH" => "US",
    "GB" => "GB",
    "IE" => "GB",
    "AU" => "GB",
    "NZ" => "GB",
    "IN" => "GB",
    "ZA" => "GB",
    "NG" => "GB",
    "KE" => "GB",
    "FR" => "GB",
    "ES" => "GB",
    "IT" => "GB",
    "PT" => "GB",
    "NL" => "GB",
    "BE" => "GB",
    "GR" => "GB",
    "IL" => "GB",
    "BR" => "GB",
    "AR" => "GB",
    "MX" => "GB",
    "CL" => "GB",
    "CO" => "GB",
    "PE" => "GB",
    "MY" => "GB",
    "SG" => "GB",
    "ID" => "GB",
    "TH" => "GB",
    "VN" => "GB",
    "DE" => "DE",
    "AT" => "DE",
    "CH" => "DE",
    "LI" => "DE",
    "LU" => "DE",
    "CZ" => "DE",
    "SK" => "DE",
    "PL" => "DE",
    "HR" => "DE",
    "SI" => "DE",
    "RS" => "DE",
    "BA" => "DE",
    "RO" => "DE",
    "BG" => "DE",
    "UA" => "DE",
    "RU" => "DE",
    "BY" => "DE",
    "FI" => "DE",
    "NO" => "DE",
    "DK" => "DE",
    "IS" => "DE",
    "EE" => "DE",
    "LV" => "DE",
    "TR" => "DE",
    "GE" => "DE",
    "AM" => "DE",
    "AZ" => "DE",
    "KZ" => "DE",
    "SE" => "ISO",
    "LT" => "ISO",
    "HU" => "ISO",
    "JP" => "ISO",
    "CN" => "ISO",
    "KR" => "ISO",
    "TW" => "ISO",
    "MN" => "ISO"
  }

  # A tag without a region subtag ("de", "en") still says something. `en` alone
  # is the one that matters here: it used to mean the US shape for every
  # non-German reader, which is the complaint issue #1502 opens with.
  @by_language %{
    "de" => "DE",
    "en" => "GB",
    "fr" => "GB",
    "es" => "GB",
    "it" => "GB",
    "pt" => "GB",
    "nl" => "GB",
    "sv" => "ISO",
    "lt" => "ISO",
    "hu" => "ISO",
    "ja" => "ISO",
    "zh" => "ISO",
    "ko" => "ISO"
  }

  @doc "The offered keys, in display order."
  def keys, do: @keys

  @doc "Whether `key` is one of the offered regions."
  def known?(key), do: key in @keys

  @doc """
  The `Calendar.strftime/2` pattern of one part of a region's shape (see
  `@parts`). Falls back to the first offered region for an unknown key, so a
  retired value in the database renders rather than raising.
  """
  def pattern(key, part) when part in @parts do
    @regions |> Map.get(key, @regions[hd(@keys)]) |> Map.fetch!(part)
  end

  @doc """
  Whether a region reads a 12- or 24-hour clock (`:h12` / `:h24`). The German
  post stamp appends "Uhr", which only means anything on a 24-hour clock.
  """
  def clock(key), do: @regions |> Map.get(key, @regions[hd(@keys)]) |> Map.fetch!(:clock)

  @doc "The regions this shape is named after, translated."
  def label("DE"), do: Gettext.gettext(VutuvWeb.Gettext, "Germany, Austria, Switzerland")
  def label("GB"), do: Gettext.gettext(VutuvWeb.Gettext, "United Kingdom, France, Brazil")
  def label("US"), do: Gettext.gettext(VutuvWeb.Gettext, "United States")
  def label("ISO"), do: Gettext.gettext(VutuvWeb.Gettext, "ISO 8601 (Sweden, Japan, China)")
  def label(key), do: key

  @doc "A worked sample of the shape, e.g. `31.12.2026, 14:30`."
  def example(key) do
    Calendar.strftime(@sample, pattern(key, :date) <> ", " <> pattern(key, :time))
  end

  @doc """
  The region a browser's `Accept-Language` header points at, or `nil` when it
  names none we have a shape for. Takes the raw header values
  (`Plug.Conn.get_req_header(conn, "accept-language")`) or a single tag.

  The first tag that resolves wins — quality values are not re-sorted, because
  a browser already sends its list in preference order and the header's own
  order is what every other reader of it uses.
  """
  def from_accept_language([header | _rest]), do: from_accept_language(header)
  def from_accept_language([]), do: nil

  def from_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.find_value(fn entry ->
      entry |> String.split(";") |> hd() |> String.trim() |> from_tag()
    end)
  end

  def from_accept_language(_other), do: nil

  # One BCP-47 tag: prefer its region subtag ("en-GB"), fall back to the bare
  # language ("en"). A script subtag ("zh-Hans-CN") keeps the region last, so
  # the region is looked for in every subtag rather than only the second.
  defp from_tag(tag) do
    case String.split(tag, "-") do
      [language | subtags] ->
        Enum.find_value(subtags, @by_language[String.downcase(language)], fn subtag ->
          @by_country[String.upcase(subtag)]
        end)

      [] ->
        nil
    end
  end
end
