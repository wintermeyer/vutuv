defmodule Vutuv.Countries do
  @moduledoc """
  Controlled-vocabulary country helper (ISO 3166-1 alpha-2).

  vutuv stores a country as its 2-letter uppercase ISO code (for example
  `"DE"`, `"AT"`, `"US"`) and never as a display name. The display name is
  derived on render from the current locale, so the same stored code shows as
  "Deutschland" to a German visitor and "Germany" to an English one. Storing
  the code keeps addresses stable across locales, sortable, and cheap to index,
  and it sidesteps the ambiguity of free-text country fields.

  This module is the single source of that vocabulary. It carries the full set
  of officially assigned ISO 3166-1 alpha-2 codes together with their English
  and German short names, and it exposes the helpers the rest of the app needs:
  validation (`valid?/1`), localized lookup (`name/2`), a sorted option list for
  form selects (`select_options/1`), the localized names of a set of codes
  (`names/2`), substring search over those names (`search/2`), the named groups
  of countries the remote-job presets are built from (`regions/1`,
  `region_codes/1`, `region_for/1`), and the small set of countries that use a
  state or province in postal addresses (`uses_state?/1`).

  vutuv supports exactly two locales, `"en"` and `"de"` (see the `:locales`
  config). An unknown locale falls back to English; an unknown code falls back
  to the uppercased code itself, so callers never have to guard against a raise.

  Used by the verified organization pages and by job postings.
  """

  # ISO 3166-1 alpha-2: {uppercase code, English short name, German short name}.
  # The full set of officially assigned codes. English and German short names
  # follow the common everyday forms (for example "United States" /
  # "Vereinigte Staaten", not the long official style).
  @countries [
    {"AD", "Andorra", "Andorra"},
    {"AE", "United Arab Emirates", "Vereinigte Arabische Emirate"},
    {"AF", "Afghanistan", "Afghanistan"},
    {"AG", "Antigua and Barbuda", "Antigua und Barbuda"},
    {"AI", "Anguilla", "Anguilla"},
    {"AL", "Albania", "Albanien"},
    {"AM", "Armenia", "Armenien"},
    {"AO", "Angola", "Angola"},
    {"AQ", "Antarctica", "Antarktis"},
    {"AR", "Argentina", "Argentinien"},
    {"AS", "American Samoa", "Amerikanisch-Samoa"},
    {"AT", "Austria", "Österreich"},
    {"AU", "Australia", "Australien"},
    {"AW", "Aruba", "Aruba"},
    {"AX", "Åland Islands", "Åland"},
    {"AZ", "Azerbaijan", "Aserbaidschan"},
    {"BA", "Bosnia and Herzegovina", "Bosnien und Herzegowina"},
    {"BB", "Barbados", "Barbados"},
    {"BD", "Bangladesh", "Bangladesch"},
    {"BE", "Belgium", "Belgien"},
    {"BF", "Burkina Faso", "Burkina Faso"},
    {"BG", "Bulgaria", "Bulgarien"},
    {"BH", "Bahrain", "Bahrain"},
    {"BI", "Burundi", "Burundi"},
    {"BJ", "Benin", "Benin"},
    {"BL", "Saint Barthélemy", "Saint-Barthélemy"},
    {"BM", "Bermuda", "Bermuda"},
    {"BN", "Brunei Darussalam", "Brunei"},
    {"BO", "Bolivia", "Bolivien"},
    {"BQ", "Bonaire, Sint Eustatius and Saba", "Bonaire, Sint Eustatius und Saba"},
    {"BR", "Brazil", "Brasilien"},
    {"BS", "Bahamas", "Bahamas"},
    {"BT", "Bhutan", "Bhutan"},
    {"BV", "Bouvet Island", "Bouvetinsel"},
    {"BW", "Botswana", "Botswana"},
    {"BY", "Belarus", "Belarus"},
    {"BZ", "Belize", "Belize"},
    {"CA", "Canada", "Kanada"},
    {"CC", "Cocos (Keeling) Islands", "Kokosinseln"},
    {"CD", "Congo (Democratic Republic)", "Kongo (Demokratische Republik)"},
    {"CF", "Central African Republic", "Zentralafrikanische Republik"},
    {"CG", "Congo", "Kongo"},
    {"CH", "Switzerland", "Schweiz"},
    {"CI", "Côte d'Ivoire", "Côte d'Ivoire"},
    {"CK", "Cook Islands", "Cookinseln"},
    {"CL", "Chile", "Chile"},
    {"CM", "Cameroon", "Kamerun"},
    {"CN", "China", "China"},
    {"CO", "Colombia", "Kolumbien"},
    {"CR", "Costa Rica", "Costa Rica"},
    {"CU", "Cuba", "Kuba"},
    {"CV", "Cabo Verde", "Kap Verde"},
    {"CW", "Curaçao", "Curaçao"},
    {"CX", "Christmas Island", "Weihnachtsinsel"},
    {"CY", "Cyprus", "Zypern"},
    {"CZ", "Czechia", "Tschechien"},
    {"DE", "Germany", "Deutschland"},
    {"DJ", "Djibouti", "Dschibuti"},
    {"DK", "Denmark", "Dänemark"},
    {"DM", "Dominica", "Dominica"},
    {"DO", "Dominican Republic", "Dominikanische Republik"},
    {"DZ", "Algeria", "Algerien"},
    {"EC", "Ecuador", "Ecuador"},
    {"EE", "Estonia", "Estland"},
    {"EG", "Egypt", "Ägypten"},
    {"EH", "Western Sahara", "Westsahara"},
    {"ER", "Eritrea", "Eritrea"},
    {"ES", "Spain", "Spanien"},
    {"ET", "Ethiopia", "Äthiopien"},
    {"FI", "Finland", "Finnland"},
    {"FJ", "Fiji", "Fidschi"},
    {"FK", "Falkland Islands", "Falklandinseln"},
    {"FM", "Micronesia", "Mikronesien"},
    {"FO", "Faroe Islands", "Färöer"},
    {"FR", "France", "Frankreich"},
    {"GA", "Gabon", "Gabun"},
    {"GB", "United Kingdom", "Vereinigtes Königreich"},
    {"GD", "Grenada", "Grenada"},
    {"GE", "Georgia", "Georgien"},
    {"GF", "French Guiana", "Französisch-Guayana"},
    {"GG", "Guernsey", "Guernsey"},
    {"GH", "Ghana", "Ghana"},
    {"GI", "Gibraltar", "Gibraltar"},
    {"GL", "Greenland", "Grönland"},
    {"GM", "Gambia", "Gambia"},
    {"GN", "Guinea", "Guinea"},
    {"GP", "Guadeloupe", "Guadeloupe"},
    {"GQ", "Equatorial Guinea", "Äquatorialguinea"},
    {"GR", "Greece", "Griechenland"},
    {"GS", "South Georgia and the South Sandwich Islands",
     "Südgeorgien und die Südlichen Sandwichinseln"},
    {"GT", "Guatemala", "Guatemala"},
    {"GU", "Guam", "Guam"},
    {"GW", "Guinea-Bissau", "Guinea-Bissau"},
    {"GY", "Guyana", "Guyana"},
    {"HK", "Hong Kong", "Hongkong"},
    {"HM", "Heard Island and McDonald Islands", "Heard und McDonaldinseln"},
    {"HN", "Honduras", "Honduras"},
    {"HR", "Croatia", "Kroatien"},
    {"HT", "Haiti", "Haiti"},
    {"HU", "Hungary", "Ungarn"},
    {"ID", "Indonesia", "Indonesien"},
    {"IE", "Ireland", "Irland"},
    {"IL", "Israel", "Israel"},
    {"IM", "Isle of Man", "Insel Man"},
    {"IN", "India", "Indien"},
    {"IO", "British Indian Ocean Territory", "Britisches Territorium im Indischen Ozean"},
    {"IQ", "Iraq", "Irak"},
    {"IR", "Iran", "Iran"},
    {"IS", "Iceland", "Island"},
    {"IT", "Italy", "Italien"},
    {"JE", "Jersey", "Jersey"},
    {"JM", "Jamaica", "Jamaika"},
    {"JO", "Jordan", "Jordanien"},
    {"JP", "Japan", "Japan"},
    {"KE", "Kenya", "Kenia"},
    {"KG", "Kyrgyzstan", "Kirgisistan"},
    {"KH", "Cambodia", "Kambodscha"},
    {"KI", "Kiribati", "Kiribati"},
    {"KM", "Comoros", "Komoren"},
    {"KN", "Saint Kitts and Nevis", "St. Kitts und Nevis"},
    {"KP", "North Korea", "Nordkorea"},
    {"KR", "South Korea", "Südkorea"},
    {"KW", "Kuwait", "Kuwait"},
    {"KY", "Cayman Islands", "Kaimaninseln"},
    {"KZ", "Kazakhstan", "Kasachstan"},
    {"LA", "Laos", "Laos"},
    {"LB", "Lebanon", "Libanon"},
    {"LC", "Saint Lucia", "St. Lucia"},
    {"LI", "Liechtenstein", "Liechtenstein"},
    {"LK", "Sri Lanka", "Sri Lanka"},
    {"LR", "Liberia", "Liberia"},
    {"LS", "Lesotho", "Lesotho"},
    {"LT", "Lithuania", "Litauen"},
    {"LU", "Luxembourg", "Luxemburg"},
    {"LV", "Latvia", "Lettland"},
    {"LY", "Libya", "Libyen"},
    {"MA", "Morocco", "Marokko"},
    {"MC", "Monaco", "Monaco"},
    {"MD", "Moldova", "Moldau"},
    {"ME", "Montenegro", "Montenegro"},
    {"MF", "Saint Martin (French part)", "Saint-Martin (französischer Teil)"},
    {"MG", "Madagascar", "Madagaskar"},
    {"MH", "Marshall Islands", "Marshallinseln"},
    {"MK", "North Macedonia", "Nordmazedonien"},
    {"ML", "Mali", "Mali"},
    {"MM", "Myanmar", "Myanmar"},
    {"MN", "Mongolia", "Mongolei"},
    {"MO", "Macao", "Macau"},
    {"MP", "Northern Mariana Islands", "Nördliche Marianen"},
    {"MQ", "Martinique", "Martinique"},
    {"MR", "Mauritania", "Mauretanien"},
    {"MS", "Montserrat", "Montserrat"},
    {"MT", "Malta", "Malta"},
    {"MU", "Mauritius", "Mauritius"},
    {"MV", "Maldives", "Malediven"},
    {"MW", "Malawi", "Malawi"},
    {"MX", "Mexico", "Mexiko"},
    {"MY", "Malaysia", "Malaysia"},
    {"MZ", "Mozambique", "Mosambik"},
    {"NA", "Namibia", "Namibia"},
    {"NC", "New Caledonia", "Neukaledonien"},
    {"NE", "Niger", "Niger"},
    {"NF", "Norfolk Island", "Norfolkinsel"},
    {"NG", "Nigeria", "Nigeria"},
    {"NI", "Nicaragua", "Nicaragua"},
    {"NL", "Netherlands", "Niederlande"},
    {"NO", "Norway", "Norwegen"},
    {"NP", "Nepal", "Nepal"},
    {"NR", "Nauru", "Nauru"},
    {"NU", "Niue", "Niue"},
    {"NZ", "New Zealand", "Neuseeland"},
    {"OM", "Oman", "Oman"},
    {"PA", "Panama", "Panama"},
    {"PE", "Peru", "Peru"},
    {"PF", "French Polynesia", "Französisch-Polynesien"},
    {"PG", "Papua New Guinea", "Papua-Neuguinea"},
    {"PH", "Philippines", "Philippinen"},
    {"PK", "Pakistan", "Pakistan"},
    {"PL", "Poland", "Polen"},
    {"PM", "Saint Pierre and Miquelon", "Saint-Pierre und Miquelon"},
    {"PN", "Pitcairn", "Pitcairninseln"},
    {"PR", "Puerto Rico", "Puerto Rico"},
    {"PS", "Palestine", "Palästina"},
    {"PT", "Portugal", "Portugal"},
    {"PW", "Palau", "Palau"},
    {"PY", "Paraguay", "Paraguay"},
    {"QA", "Qatar", "Katar"},
    {"RE", "Réunion", "Réunion"},
    {"RO", "Romania", "Rumänien"},
    {"RS", "Serbia", "Serbien"},
    {"RU", "Russia", "Russland"},
    {"RW", "Rwanda", "Ruanda"},
    {"SA", "Saudi Arabia", "Saudi-Arabien"},
    {"SB", "Solomon Islands", "Salomonen"},
    {"SC", "Seychelles", "Seychellen"},
    {"SD", "Sudan", "Sudan"},
    {"SE", "Sweden", "Schweden"},
    {"SG", "Singapore", "Singapur"},
    {"SH", "Saint Helena, Ascension and Tristan da Cunha",
     "St. Helena, Ascension und Tristan da Cunha"},
    {"SI", "Slovenia", "Slowenien"},
    {"SJ", "Svalbard and Jan Mayen", "Svalbard und Jan Mayen"},
    {"SK", "Slovakia", "Slowakei"},
    {"SL", "Sierra Leone", "Sierra Leone"},
    {"SM", "San Marino", "San Marino"},
    {"SN", "Senegal", "Senegal"},
    {"SO", "Somalia", "Somalia"},
    {"SR", "Suriname", "Suriname"},
    {"SS", "South Sudan", "Südsudan"},
    {"ST", "Sao Tome and Principe", "São Tomé und Príncipe"},
    {"SV", "El Salvador", "El Salvador"},
    {"SX", "Sint Maarten (Dutch part)", "Sint Maarten (niederländischer Teil)"},
    {"SY", "Syria", "Syrien"},
    {"SZ", "Eswatini", "Eswatini"},
    {"TC", "Turks and Caicos Islands", "Turks- und Caicosinseln"},
    {"TD", "Chad", "Tschad"},
    {"TF", "French Southern Territories", "Französische Süd- und Antarktisgebiete"},
    {"TG", "Togo", "Togo"},
    {"TH", "Thailand", "Thailand"},
    {"TJ", "Tajikistan", "Tadschikistan"},
    {"TK", "Tokelau", "Tokelau"},
    {"TL", "Timor-Leste", "Timor-Leste"},
    {"TM", "Turkmenistan", "Turkmenistan"},
    {"TN", "Tunisia", "Tunesien"},
    {"TO", "Tonga", "Tonga"},
    {"TR", "Türkiye", "Türkei"},
    {"TT", "Trinidad and Tobago", "Trinidad und Tobago"},
    {"TV", "Tuvalu", "Tuvalu"},
    {"TW", "Taiwan", "Taiwan"},
    {"TZ", "Tanzania", "Tansania"},
    {"UA", "Ukraine", "Ukraine"},
    {"UG", "Uganda", "Uganda"},
    {"UM", "United States Minor Outlying Islands", "Amerikanische Überseeinseln"},
    {"US", "United States", "Vereinigte Staaten"},
    {"UY", "Uruguay", "Uruguay"},
    {"UZ", "Uzbekistan", "Usbekistan"},
    {"VA", "Vatican City", "Vatikanstadt"},
    {"VC", "Saint Vincent and the Grenadines", "St. Vincent und die Grenadinen"},
    {"VE", "Venezuela", "Venezuela"},
    {"VG", "Virgin Islands (British)", "Britische Jungferninseln"},
    {"VI", "Virgin Islands (U.S.)", "Amerikanische Jungferninseln"},
    {"VN", "Vietnam", "Vietnam"},
    {"VU", "Vanuatu", "Vanuatu"},
    {"WF", "Wallis and Futuna", "Wallis und Futuna"},
    {"WS", "Samoa", "Samoa"},
    {"YE", "Yemen", "Jemen"},
    {"YT", "Mayotte", "Mayotte"},
    {"ZA", "South Africa", "Südafrika"},
    {"ZM", "Zambia", "Sambia"},
    {"ZW", "Zimbabwe", "Simbabwe"}
  ]

  # Fast lookup by code, and the ordered list of codes, both built at compile time.
  @by_code Map.new(@countries, fn {code, en, de} -> {code, %{en: en, de: de}} end)
  @codes Enum.map(@countries, fn {code, _en, _de} -> code end)

  # Countries that customarily carry a state, province, or region in a postal
  # address. Kept deliberately small: the large federations whose mail routing
  # genuinely depends on the subdivision. Most countries (Germany, France, the
  # UK, ...) address purely by city and postal code, so they are omitted.
  @state_countries ~w(US CA AU BR IN MX CN)

  # Named groups of countries, the vocabulary the remote-job presets are built
  # from (issue #1559). Membership is spelled out as codes rather than derived,
  # because these are business conventions and not geography: Turkey counts as
  # Middle East, Cyprus as Europe, Central Asia as APAC, and every one of those
  # is a judgement call somebody has to be able to read and correct.
  #
  # What IS derived is every overlap that moves: Europe is the union with the
  # EU rather than a second copy of its 27, and EMEA is composed from its three
  # parts rather than listed a fourth time. An accession then has one place to
  # be remembered.
  @eu ~w(AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT
         RO SE SI SK)
  @europe @eu ++
            ~w(AD AL AM AX AZ BA BY CH FO GB GE GG GI IM IS JE LI MC MD ME MK
               NO RS RU SJ SM UA VA)
  @middle_east ~w(AE BH IL IQ IR JO KW LB OM PS QA SA SY TR YE)
  @africa ~w(AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG EH ER ET GA GH GM GN GQ
             GW KE KM LR LS LY MA MG ML MR MU MW MZ NA NE NG RE RW SC SD SH SL
             SN SO SS ST SZ TD TG TN TZ UG YT ZA ZM ZW)
  @mena ~w(AE BH DZ EG IL IQ IR JO KW LB LY MA OM PS QA SA SY TN YE)
  @apac ~w(AF AS AU BD BN BT CC CK CN CX FJ FM GU HK ID IN JP KG KH KI KP KR KZ
           LA LK MH MM MN MO MP MV MY NC NF NP NR NU NZ PF PG PH PK PN PW SB SG
           TH TJ TK TL TM TO TV TW UZ VN VU WF WS)

  # {key, English name, German name, codes}. The key is the acronym the preset
  # button shows and is deliberately not translated: EU / EMEA / MENA / APAC are
  # the words a recruiter writes in either language. Codes are stored sorted, so
  # `region_for/1` can compare a selection against them directly.
  @regions [
    {"EU", "European Union", "Europäische Union", Enum.sort(@eu)},
    {"EMEA", "Europe, Middle East and Africa", "Europa, Naher Osten und Afrika",
     Enum.sort(Enum.uniq(@europe ++ @middle_east ++ @africa))},
    {"MENA", "Middle East and North Africa", "Naher Osten und Nordafrika", Enum.sort(@mena)},
    {"APAC", "Asia-Pacific", "Asien-Pazifik", Enum.sort(@apac)}
  ]

  # A region naming a code this module does not know is a typo, and a typo here
  # is a preset that silently drops a country. Fail the build on it.
  for {key, _en, _de, codes} <- @regions, code <- codes do
    unless Map.has_key?(@by_code, code) do
      raise "Vutuv.Countries: region #{key} lists unknown country code #{inspect(code)}"
    end
  end

  @region_codes Map.new(@regions, fn {key, _en, _de, codes} -> {key, codes} end)

  @doc """
  All country codes as uppercase alpha-2 strings, in ISO code order.
  """
  @spec all() :: [String.t()]
  def all, do: @codes

  @doc """
  True only for a known, uppercase ISO 3166-1 alpha-2 code.

  Returns false for `nil`, `""`, lowercase input, unknown codes, and any
  non-binary value.
  """
  @spec valid?(term()) :: boolean()
  def valid?(code) when is_binary(code), do: Map.has_key?(@by_code, code)
  def valid?(_code), do: false

  @doc """
  The localized display name for a country code.

  `locale` may be `"de"`, `"en"`, `:de`, `:en`, or `nil`. When `nil`, the
  current gettext locale is read from `VutuvWeb.Gettext`. An unknown locale
  falls back to English. An unknown or invalid code returns the uppercased code
  itself as a harmless fallback, so this never raises.
  """
  @spec name(term(), String.t() | atom() | nil) :: String.t()
  def name(code, locale \\ nil)

  def name(code, locale) when is_binary(code) do
    case Map.get(@by_code, code) do
      nil -> String.upcase(code)
      names -> Map.fetch!(names, normalize_locale(locale))
    end
  end

  def name(code, _locale), do: to_string(code)

  @doc """
  Options for a country select, as `{localized_name, code}` tuples sorted by the
  localized name.

  The sort uses a diacritic-folded key so that, in German, "Ägypten" sorts near
  "A" and "Österreich" near "O" rather than after "Z". The folding only affects
  ordering; the displayed name keeps its umlauts and accents. Shaped for
  `Phoenix.HTML.Form.select/4` and for a plain `<option>` loop.
  """
  @spec select_options(String.t() | atom() | nil) :: [{String.t(), String.t()}]
  def select_options(locale \\ nil) do
    resolved = normalize_locale(locale)

    @countries
    |> Enum.map(fn {code, en, de} ->
      display = if resolved == :de, do: de, else: en
      {display, code}
    end)
    |> Enum.sort_by(fn {display, _code} -> fold(display) end)
  end

  @doc """
  `codes` as `{localized_name, code}` tuples, sorted like `select_options/1`.

  Unknown codes are dropped and duplicates collapse, so this is also the
  narrowing step for a stored list: whatever comes back is a name a reader can
  act on.
  """
  @spec names([String.t()], String.t() | atom() | nil) :: [{String.t(), String.t()}]
  def names(codes, locale \\ nil)

  def names([], _locale), do: []

  def names(codes, locale) when is_list(codes) do
    codes
    |> Enum.uniq()
    |> Enum.filter(&valid?/1)
    |> Enum.map(&{name(&1, locale), &1})
    |> Enum.sort_by(fn {display, _code} -> fold(display) end)
  end

  def names(_codes, _locale), do: []

  @doc """
  Countries whose localized name contains `query`, as `{localized_name, code}`
  tuples in the same order `select_options/1` uses.

  The match is diacritic-folded and case-insensitive on both sides (the same
  folding the sort uses), so "osterreich" finds Österreich and "cote" finds
  Côte d'Ivoire — a member typing into a picker cannot be asked to produce an
  umlaut before the country they want shows up. A two-letter query also matches
  that ISO code exactly, and the code match is listed first: "AT" means Austria
  to anyone who types it, even though it is also a substring of "Guatemala".

  Hits are ranked before they are sorted — a name that *begins* with the query
  first, then one whose later words do, then a match anywhere. Alphabetical
  order alone answered "sch" with Amerikanisch-Samoa and Aserbaidschan while
  Schweiz fell outside the first eight, which is the whole list a picker shows.

  A blank query returns `[]` rather than all 249 countries: the caller is a
  search box, and "nothing typed" means "nothing to show", not "show
  everything".
  """
  @spec search(term(), String.t() | atom() | nil) :: [{String.t(), String.t()}]
  def search(query, locale \\ nil)

  def search(query, locale) when is_binary(query) do
    trimmed = String.trim(query)
    needle = fold(trimmed)
    exact = String.upcase(trimmed)

    cond do
      needle == "" ->
        []

      valid?(exact) ->
        [{name(exact, locale), exact} | by_name(needle, locale, exact)]

      true ->
        by_name(needle, locale, nil)
    end
  end

  def search(_query, _locale), do: []

  defp by_name(needle, locale, skip) do
    locale
    |> select_options()
    |> Enum.reject(fn {_name, code} -> code == skip end)
    |> Enum.map(fn {name, code} -> {rank(fold(name), needle), name, code} end)
    |> Enum.filter(fn {rank, _name, _code} -> rank end)
    |> Enum.sort_by(fn {rank, _name, _code} -> rank end)
    |> Enum.map(fn {_rank, name, code} -> {name, code} end)
  end

  # 0 = the name begins with what was typed, 1 = a word inside it does, 2 = it
  # merely occurs somewhere, nil = no match. Without this, "sch" answered
  # alphabetically with Amerikanisch-Samoa, Aserbaidschan and Bangladesch, and
  # Schweiz was nowhere in the first eight hits. `Enum.sort_by/2` is stable, so
  # each band keeps the option list's own alphabetical order.
  defp rank(folded, needle) do
    cond do
      String.starts_with?(folded, needle) -> 0
      String.contains?(folded, " " <> needle) -> 1
      String.contains?(folded, "-" <> needle) -> 1
      String.contains?(folded, needle) -> 2
      true -> nil
    end
  end

  @doc """
  The regions, in display order, as
  `%{key: "EU", name: "Europäische Union", count: 27}`.

  `key` is the acronym a preset button shows, `name` the localized long form for
  its tooltip, `count` how many countries the preset adds. Ask `region_codes/1`
  for the expansion itself — that is what gets stored:
  `Vutuv.Jobs.filter_location/4` matches a searched country against
  `job_postings.remote_countries`, so a posting advertised for "EU" has to carry
  the 27 codes rather than the word.
  """
  @spec regions(String.t() | atom() | nil) :: [
          %{key: String.t(), name: String.t(), count: non_neg_integer()}
        ]
  def regions(locale \\ nil) do
    resolved = normalize_locale(locale)

    Enum.map(@regions, fn {key, en, de, codes} ->
      %{key: key, name: if(resolved == :de, do: de, else: en), count: length(codes)}
    end)
  end

  @doc "The country codes of one region key, or `[]` for anything unknown."
  @spec region_codes(term()) :: [String.t()]
  def region_codes(key) when is_binary(key), do: Map.get(@region_codes, key, [])
  def region_codes(_key), do: []

  @doc """
  The region key `codes` covers exactly, or `nil`.

  Used to say "Remote (EU)" instead of listing 27 codes on a job card. Exact
  set equality only: a member who takes one country back out of a preset means
  something narrower than the region, and naming it anyway would misdescribe
  where they will hire.
  """
  @spec region_for(term()) :: String.t() | nil
  def region_for(codes) when is_list(codes) do
    sorted = codes |> Enum.uniq() |> Enum.sort()

    Enum.find_value(@regions, fn {key, _en, _de, region_codes} ->
      if sorted == region_codes, do: key
    end)
  end

  def region_for(_codes), do: nil

  @doc """
  True only for the small set of countries that customarily use a state,
  province, or region in a postal address.

  The list is `US`, `CA`, `AU`, `BR`, `IN`, `MX`, and `CN` - large federations
  whose mail routing depends on the subdivision. Everything else addresses by
  city and postal code, so it returns false (including `nil` and non-binary
  input).
  """
  @spec uses_state?(term()) :: boolean()
  def uses_state?(code) when is_binary(code), do: code in @state_countries
  def uses_state?(_code), do: false

  @doc """
  Diacritic-folded, case-insensitive key for a country name. Public because it
  is the ordering `select_options/1` promises and the matching `search/2`
  performs, so a caller asserting on either needs the same rule rather than a
  copy of it.

  Decomposing to NFD and dropping the combining marks folds every accent the
  names carry — not a hand-kept list of the ones somebody thought of, which is
  how "Côte d'Ivoire" stayed unreachable by "cote". Eszett is spelled out
  because it has no decomposition. Not a slug:
  `Vutuv.SlugHelpers.transliterate/1` deliberately spells "ä" as "ae", which is
  right for a URL and wrong here.
  """
  @spec fold(String.t()) :: String.t()
  def fold(display) do
    display
    |> String.downcase()
    |> String.replace("ß", "ss")
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  # Normalize a locale argument to a known atom without ever calling
  # String.to_atom on caller input. Anything unrecognized falls back to English.
  defp normalize_locale(:de), do: :de
  defp normalize_locale(:en), do: :en
  defp normalize_locale("de"), do: :de
  defp normalize_locale("en"), do: :en

  defp normalize_locale(nil) do
    case Gettext.get_locale(VutuvWeb.Gettext) do
      "de" -> :de
      _other -> :en
    end
  end

  defp normalize_locale(_other), do: :en
end
