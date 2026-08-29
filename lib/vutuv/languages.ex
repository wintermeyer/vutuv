defmodule Vutuv.Languages do
  @moduledoc """
  The curated set of languages a member can list on their profile (issue
  #865, "spoken languages").

  Each language is stored by its **ISO 639-1 code** ("en", "de") so the data
  is machine-readable (a BCP 47 primary subtag), consistent across members
  and localizable — the display name comes from `name/1`, rendered through
  Gettext in the viewer's locale, so the same "en" reads "English" for one
  visitor and "Englisch" for another.

  The list is deliberately a broad but finite selection of the world's most
  spoken languages rather than the full ~180-entry ISO register: a member
  picks from a `<select>`, and every name here carries a German translation
  in the `.po` files. `known?/1` gates the changeset, so a stray code can
  never be stored.
  """

  use Gettext, backend: VutuvWeb.Gettext

  # {ISO 639-1 code, English name}. The English name doubles as the Gettext
  # msgid; the German msgstrs live in the `.po` files. Ordered roughly by
  # number of speakers / European relevance, but `options/0` re-sorts by the
  # localized name for display.
  @languages [
    {"en", "English"},
    {"de", "German"},
    {"fr", "French"},
    {"es", "Spanish"},
    {"pt", "Portuguese"},
    {"it", "Italian"},
    {"nl", "Dutch"},
    {"ru", "Russian"},
    {"uk", "Ukrainian"},
    {"pl", "Polish"},
    {"cs", "Czech"},
    {"sk", "Slovak"},
    {"hu", "Hungarian"},
    {"ro", "Romanian"},
    {"bg", "Bulgarian"},
    {"el", "Greek"},
    {"hr", "Croatian"},
    {"sr", "Serbian"},
    {"sl", "Slovenian"},
    {"bs", "Bosnian"},
    {"sq", "Albanian"},
    {"lt", "Lithuanian"},
    {"lv", "Latvian"},
    {"et", "Estonian"},
    {"fi", "Finnish"},
    {"sv", "Swedish"},
    {"no", "Norwegian"},
    {"da", "Danish"},
    {"is", "Icelandic"},
    {"ga", "Irish"},
    {"cy", "Welsh"},
    {"ca", "Catalan"},
    {"eu", "Basque"},
    {"gl", "Galician"},
    {"mt", "Maltese"},
    {"tr", "Turkish"},
    {"ar", "Arabic"},
    {"he", "Hebrew"},
    {"fa", "Persian"},
    {"ku", "Kurdish"},
    {"hi", "Hindi"},
    {"ur", "Urdu"},
    {"bn", "Bengali"},
    {"pa", "Punjabi"},
    {"ta", "Tamil"},
    {"te", "Telugu"},
    {"zh", "Chinese"},
    {"ja", "Japanese"},
    {"ko", "Korean"},
    {"vi", "Vietnamese"},
    {"th", "Thai"},
    {"id", "Indonesian"},
    {"ms", "Malay"},
    {"tl", "Tagalog"},
    {"sw", "Swahili"},
    {"am", "Amharic"},
    {"ha", "Hausa"},
    {"yo", "Yoruba"},
    {"af", "Afrikaans"},
    {"az", "Azerbaijani"},
    {"ka", "Georgian"},
    {"hy", "Armenian"},
    {"kk", "Kazakh"},
    {"uz", "Uzbek"}
  ]

  @codes Enum.map(@languages, &elem(&1, 0))
  @code_set MapSet.new(@codes)

  @doc "Every known language code (ISO 639-1)."
  def codes, do: @codes

  @doc """
  The locales this installation serves its UI in — the Endpoint's `:locales`
  config, the same list `VutuvWeb.Plug.Locale` negotiates against. The one
  public reader, so the composer's language select and the popular-posts
  pools cannot each grow their own copy of where that list lives.
  """
  def site_locales do
    :vutuv
    |> Application.get_env(VutuvWeb.Endpoint, [])
    |> Keyword.get(:locales, ["en"])
  end

  @doc """
  The language to tell somebody else this member reads, or `"en"` for a member
  who never chose.

  Deliberately **not** clamped to `site_locales/0`, which is the difference
  between naming a locale and rendering in one. `Vutuv.Notifications.Emailer`
  has to render, so it refuses a locale we hold no translations for; a Web Push
  payload only *names* the language, and the reader on the other end may have
  strings we do not — a third-party Mastodon client with a French translation
  should be told "fr" rather than "en" (`Vutuv.MastodonApi.PushDispatcher`),
  and our own service worker falls back to its own table on a locale it was
  given no line for (`Vutuv.WebPush.Dispatcher`).

  vutuv is installable by third parties, so the fallback is the same `"en"`
  `VutuvWeb.Plug.Locale` falls back to, never a hardcoded `"de"` — a push and
  the website must not disagree about what language they think this person
  reads.
  """
  def user_locale(locale) when is_binary(locale) and locale != "", do: locale
  def user_locale(_no_choice), do: "en"

  @doc "Whether `code` is one of the curated languages."
  def known?(code) when is_binary(code), do: MapSet.member?(@code_set, code)
  def known?(_code), do: false

  @doc """
  The localized display name of a language code, e.g. `"en"` -> "English" /
  "Englisch". An unknown code falls back to the code itself (uppercased), so
  a legacy or hand-inserted value never crashes a render.
  """
  def name(code)

  # Generate one clause per language. `gettext(unquote(english))` unquotes the
  # name into a string literal *before* the gettext macro sees it, so
  # `mix gettext.extract` still picks every name up as a msgid.
  for {code, english} <- @languages do
    def name(unquote(code)), do: gettext(unquote(english))
  end

  def name(code) when is_binary(code), do: String.upcase(code)

  @doc """
  The `{localized_name, code}` options for the language `<select>`, sorted by
  the localized name so the list reads alphabetically in the viewer's locale.
  """
  def options do
    @codes
    |> Enum.map(&{name(&1), &1})
    |> Enum.sort_by(fn {label, _code} -> String.downcase(label) end)
  end
end
