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

  One column per interface locale (see the `:locales` config). An unknown
  locale falls back to English; an unknown code falls back to the uppercased
  code itself, so callers never have to guard against a raise.

  Used by the verified organization pages and by job postings.
  """

  # ISO 3166-1 alpha-2: {uppercase code, English, German, French, Italian short
  # name}.
  # The full set of officially assigned codes, one column per interface
  # language. The short names follow the common everyday forms (for example
  # "United States" / "Vereinigte Staaten" / "Stati Uniti", not the long
  # official style).
  @countries [
    {"AD", "Andorra", "Andorra", "Andorre", "Andorra"},
    {"AE", "United Arab Emirates", "Vereinigte Arabische Emirate", "Émirats arabes unis",
     "Emirati Arabi Uniti"},
    {"AF", "Afghanistan", "Afghanistan", "Afghanistan", "Afghanistan"},
    {"AG", "Antigua and Barbuda", "Antigua und Barbuda", "Antigua-et-Barbuda",
     "Antigua e Barbuda"},
    {"AI", "Anguilla", "Anguilla", "Anguilla", "Anguilla"},
    {"AL", "Albania", "Albanien", "Albanie", "Albania"},
    {"AM", "Armenia", "Armenien", "Arménie", "Armenia"},
    {"AO", "Angola", "Angola", "Angola", "Angola"},
    {"AQ", "Antarctica", "Antarktis", "Antarctique", "Antartide"},
    {"AR", "Argentina", "Argentinien", "Argentine", "Argentina"},
    {"AS", "American Samoa", "Amerikanisch-Samoa", "Samoa américaines", "Samoa Americane"},
    {"AT", "Austria", "Österreich", "Autriche", "Austria"},
    {"AU", "Australia", "Australien", "Australie", "Australia"},
    {"AW", "Aruba", "Aruba", "Aruba", "Aruba"},
    {"AX", "Åland Islands", "Åland", "Îles Åland", "Isole Åland"},
    {"AZ", "Azerbaijan", "Aserbaidschan", "Azerbaïdjan", "Azerbaigian"},
    {"BA", "Bosnia and Herzegovina", "Bosnien und Herzegowina", "Bosnie-Herzégovine",
     "Bosnia ed Erzegovina"},
    {"BB", "Barbados", "Barbados", "Barbade", "Barbados"},
    {"BD", "Bangladesh", "Bangladesch", "Bangladesh", "Bangladesh"},
    {"BE", "Belgium", "Belgien", "Belgique", "Belgio"},
    {"BF", "Burkina Faso", "Burkina Faso", "Burkina Faso", "Burkina Faso"},
    {"BG", "Bulgaria", "Bulgarien", "Bulgarie", "Bulgaria"},
    {"BH", "Bahrain", "Bahrain", "Bahreïn", "Bahrein"},
    {"BI", "Burundi", "Burundi", "Burundi", "Burundi"},
    {"BJ", "Benin", "Benin", "Bénin", "Benin"},
    {"BL", "Saint Barthélemy", "Saint-Barthélemy", "Saint-Barthélemy", "Saint-Barthélemy"},
    {"BM", "Bermuda", "Bermuda", "Bermudes", "Bermuda"},
    {"BN", "Brunei Darussalam", "Brunei", "Brunei", "Brunei"},
    {"BO", "Bolivia", "Bolivien", "Bolivie", "Bolivia"},
    {"BQ", "Bonaire, Sint Eustatius and Saba", "Bonaire, Sint Eustatius und Saba",
     "Pays-Bas caribéens", "Caraibi olandesi"},
    {"BR", "Brazil", "Brasilien", "Brésil", "Brasile"},
    {"BS", "Bahamas", "Bahamas", "Bahamas", "Bahamas"},
    {"BT", "Bhutan", "Bhutan", "Bhoutan", "Bhutan"},
    {"BV", "Bouvet Island", "Bouvetinsel", "Île Bouvet", "Isola Bouvet"},
    {"BW", "Botswana", "Botswana", "Botswana", "Botswana"},
    {"BY", "Belarus", "Belarus", "Biélorussie", "Bielorussia"},
    {"BZ", "Belize", "Belize", "Belize", "Belize"},
    {"CA", "Canada", "Kanada", "Canada", "Canada"},
    {"CC", "Cocos (Keeling) Islands", "Kokosinseln", "Îles Cocos", "Isole Cocos"},
    {"CD", "Congo (Democratic Republic)", "Kongo (Demokratische Republik)", "Congo-Kinshasa",
     "Repubblica Democratica del Congo"},
    {"CF", "Central African Republic", "Zentralafrikanische Republik",
     "République centrafricaine", "Repubblica Centrafricana"},
    {"CG", "Congo", "Kongo", "Congo-Brazzaville", "Congo"},
    {"CH", "Switzerland", "Schweiz", "Suisse", "Svizzera"},
    {"CI", "Côte d'Ivoire", "Côte d'Ivoire", "Côte d'Ivoire", "Costa d'Avorio"},
    {"CK", "Cook Islands", "Cookinseln", "Îles Cook", "Isole Cook"},
    {"CL", "Chile", "Chile", "Chili", "Cile"},
    {"CM", "Cameroon", "Kamerun", "Cameroun", "Camerun"},
    {"CN", "China", "China", "Chine", "Cina"},
    {"CO", "Colombia", "Kolumbien", "Colombie", "Colombia"},
    {"CR", "Costa Rica", "Costa Rica", "Costa Rica", "Costa Rica"},
    {"CU", "Cuba", "Kuba", "Cuba", "Cuba"},
    {"CV", "Cabo Verde", "Kap Verde", "Cap-Vert", "Capo Verde"},
    {"CW", "Curaçao", "Curaçao", "Curaçao", "Curaçao"},
    {"CX", "Christmas Island", "Weihnachtsinsel", "Île Christmas", "Isola di Natale"},
    {"CY", "Cyprus", "Zypern", "Chypre", "Cipro"},
    {"CZ", "Czechia", "Tschechien", "Tchéquie", "Cechia"},
    {"DE", "Germany", "Deutschland", "Allemagne", "Germania"},
    {"DJ", "Djibouti", "Dschibuti", "Djibouti", "Gibuti"},
    {"DK", "Denmark", "Dänemark", "Danemark", "Danimarca"},
    {"DM", "Dominica", "Dominica", "Dominique", "Dominica"},
    {"DO", "Dominican Republic", "Dominikanische Republik", "République dominicaine",
     "Repubblica Dominicana"},
    {"DZ", "Algeria", "Algerien", "Algérie", "Algeria"},
    {"EC", "Ecuador", "Ecuador", "Équateur", "Ecuador"},
    {"EE", "Estonia", "Estland", "Estonie", "Estonia"},
    {"EG", "Egypt", "Ägypten", "Égypte", "Egitto"},
    {"EH", "Western Sahara", "Westsahara", "Sahara occidental", "Sahara Occidentale"},
    {"ER", "Eritrea", "Eritrea", "Érythrée", "Eritrea"},
    {"ES", "Spain", "Spanien", "Espagne", "Spagna"},
    {"ET", "Ethiopia", "Äthiopien", "Éthiopie", "Etiopia"},
    {"FI", "Finland", "Finnland", "Finlande", "Finlandia"},
    {"FJ", "Fiji", "Fidschi", "Fidji", "Figi"},
    {"FK", "Falkland Islands", "Falklandinseln", "Îles Malouines", "Isole Falkland"},
    {"FM", "Micronesia", "Mikronesien", "Micronésie", "Micronesia"},
    {"FO", "Faroe Islands", "Färöer", "Îles Féroé", "Isole Fær Øer"},
    {"FR", "France", "Frankreich", "France", "Francia"},
    {"GA", "Gabon", "Gabun", "Gabon", "Gabon"},
    {"GB", "United Kingdom", "Vereinigtes Königreich", "Royaume-Uni", "Regno Unito"},
    {"GD", "Grenada", "Grenada", "Grenade", "Grenada"},
    {"GE", "Georgia", "Georgien", "Géorgie", "Georgia"},
    {"GF", "French Guiana", "Französisch-Guayana", "Guyane française", "Guyana francese"},
    {"GG", "Guernsey", "Guernsey", "Guernesey", "Guernsey"},
    {"GH", "Ghana", "Ghana", "Ghana", "Ghana"},
    {"GI", "Gibraltar", "Gibraltar", "Gibraltar", "Gibilterra"},
    {"GL", "Greenland", "Grönland", "Groenland", "Groenlandia"},
    {"GM", "Gambia", "Gambia", "Gambie", "Gambia"},
    {"GN", "Guinea", "Guinea", "Guinée", "Guinea"},
    {"GP", "Guadeloupe", "Guadeloupe", "Guadeloupe", "Guadalupa"},
    {"GQ", "Equatorial Guinea", "Äquatorialguinea", "Guinée équatoriale", "Guinea Equatoriale"},
    {"GR", "Greece", "Griechenland", "Grèce", "Grecia"},
    {"GS", "South Georgia and the South Sandwich Islands",
     "Südgeorgien und die Südlichen Sandwichinseln", "Géorgie du Sud-et-les Îles Sandwich du Sud",
     "Georgia del Sud e Sandwich Australi"},
    {"GT", "Guatemala", "Guatemala", "Guatemala", "Guatemala"},
    {"GU", "Guam", "Guam", "Guam", "Guam"},
    {"GW", "Guinea-Bissau", "Guinea-Bissau", "Guinée-Bissau", "Guinea-Bissau"},
    {"GY", "Guyana", "Guyana", "Guyana", "Guyana"},
    {"HK", "Hong Kong", "Hongkong", "R.A.S. chinoise de Hong Kong", "Hong Kong"},
    {"HM", "Heard Island and McDonald Islands", "Heard und McDonaldinseln",
     "Îles Heard-et-MacDonald", "Isole Heard e McDonald"},
    {"HN", "Honduras", "Honduras", "Honduras", "Honduras"},
    {"HR", "Croatia", "Kroatien", "Croatie", "Croazia"},
    {"HT", "Haiti", "Haiti", "Haïti", "Haiti"},
    {"HU", "Hungary", "Ungarn", "Hongrie", "Ungheria"},
    {"ID", "Indonesia", "Indonesien", "Indonésie", "Indonesia"},
    {"IE", "Ireland", "Irland", "Irlande", "Irlanda"},
    {"IL", "Israel", "Israel", "Israël", "Israele"},
    {"IM", "Isle of Man", "Insel Man", "Île de Man", "Isola di Man"},
    {"IN", "India", "Indien", "Inde", "India"},
    {"IO", "British Indian Ocean Territory", "Britisches Territorium im Indischen Ozean",
     "Territoire britannique de l'océan Indien", "Territorio britannico dell'Oceano Indiano"},
    {"IQ", "Iraq", "Irak", "Irak", "Iraq"},
    {"IR", "Iran", "Iran", "Iran", "Iran"},
    {"IS", "Iceland", "Island", "Islande", "Islanda"},
    {"IT", "Italy", "Italien", "Italie", "Italia"},
    {"JE", "Jersey", "Jersey", "Jersey", "Jersey"},
    {"JM", "Jamaica", "Jamaika", "Jamaïque", "Giamaica"},
    {"JO", "Jordan", "Jordanien", "Jordanie", "Giordania"},
    {"JP", "Japan", "Japan", "Japon", "Giappone"},
    {"KE", "Kenya", "Kenia", "Kenya", "Kenya"},
    {"KG", "Kyrgyzstan", "Kirgisistan", "Kirghizstan", "Kirghizistan"},
    {"KH", "Cambodia", "Kambodscha", "Cambodge", "Cambogia"},
    {"KI", "Kiribati", "Kiribati", "Kiribati", "Kiribati"},
    {"KM", "Comoros", "Komoren", "Comores", "Comore"},
    {"KN", "Saint Kitts and Nevis", "St. Kitts und Nevis", "Saint-Christophe-et-Niévès",
     "Saint Kitts e Nevis"},
    {"KP", "North Korea", "Nordkorea", "Corée du Nord", "Corea del Nord"},
    {"KR", "South Korea", "Südkorea", "Corée du Sud", "Corea del Sud"},
    {"KW", "Kuwait", "Kuwait", "Koweït", "Kuwait"},
    {"KY", "Cayman Islands", "Kaimaninseln", "Îles Caïmans", "Isole Cayman"},
    {"KZ", "Kazakhstan", "Kasachstan", "Kazakhstan", "Kazakistan"},
    {"LA", "Laos", "Laos", "Laos", "Laos"},
    {"LB", "Lebanon", "Libanon", "Liban", "Libano"},
    {"LC", "Saint Lucia", "St. Lucia", "Sainte-Lucie", "Santa Lucia"},
    {"LI", "Liechtenstein", "Liechtenstein", "Liechtenstein", "Liechtenstein"},
    {"LK", "Sri Lanka", "Sri Lanka", "Sri Lanka", "Sri Lanka"},
    {"LR", "Liberia", "Liberia", "Liberia", "Liberia"},
    {"LS", "Lesotho", "Lesotho", "Lesotho", "Lesotho"},
    {"LT", "Lithuania", "Litauen", "Lituanie", "Lituania"},
    {"LU", "Luxembourg", "Luxemburg", "Luxembourg", "Lussemburgo"},
    {"LV", "Latvia", "Lettland", "Lettonie", "Lettonia"},
    {"LY", "Libya", "Libyen", "Libye", "Libia"},
    {"MA", "Morocco", "Marokko", "Maroc", "Marocco"},
    {"MC", "Monaco", "Monaco", "Monaco", "Monaco"},
    {"MD", "Moldova", "Moldau", "Moldavie", "Moldavia"},
    {"ME", "Montenegro", "Montenegro", "Monténégro", "Montenegro"},
    {"MF", "Saint Martin (French part)", "Saint-Martin (französischer Teil)", "Saint-Martin",
     "Saint-Martin"},
    {"MG", "Madagascar", "Madagaskar", "Madagascar", "Madagascar"},
    {"MH", "Marshall Islands", "Marshallinseln", "Îles Marshall", "Isole Marshall"},
    {"MK", "North Macedonia", "Nordmazedonien", "Macédoine du Nord", "Macedonia del Nord"},
    {"ML", "Mali", "Mali", "Mali", "Mali"},
    {"MM", "Myanmar", "Myanmar", "Myanmar (Birmanie)", "Myanmar"},
    {"MN", "Mongolia", "Mongolei", "Mongolie", "Mongolia"},
    {"MO", "Macao", "Macau", "R.A.S. chinoise de Macao", "Macao"},
    {"MP", "Northern Mariana Islands", "Nördliche Marianen", "Îles Mariannes du Nord",
     "Isole Marianne Settentrionali"},
    {"MQ", "Martinique", "Martinique", "Martinique", "Martinica"},
    {"MR", "Mauritania", "Mauretanien", "Mauritanie", "Mauritania"},
    {"MS", "Montserrat", "Montserrat", "Montserrat", "Montserrat"},
    {"MT", "Malta", "Malta", "Malte", "Malta"},
    {"MU", "Mauritius", "Mauritius", "Maurice", "Mauritius"},
    {"MV", "Maldives", "Malediven", "Maldives", "Maldive"},
    {"MW", "Malawi", "Malawi", "Malawi", "Malawi"},
    {"MX", "Mexico", "Mexiko", "Mexique", "Messico"},
    {"MY", "Malaysia", "Malaysia", "Malaisie", "Malaysia"},
    {"MZ", "Mozambique", "Mosambik", "Mozambique", "Mozambico"},
    {"NA", "Namibia", "Namibia", "Namibie", "Namibia"},
    {"NC", "New Caledonia", "Neukaledonien", "Nouvelle-Calédonie", "Nuova Caledonia"},
    {"NE", "Niger", "Niger", "Niger", "Niger"},
    {"NF", "Norfolk Island", "Norfolkinsel", "Île Norfolk", "Isola Norfolk"},
    {"NG", "Nigeria", "Nigeria", "Nigeria", "Nigeria"},
    {"NI", "Nicaragua", "Nicaragua", "Nicaragua", "Nicaragua"},
    {"NL", "Netherlands", "Niederlande", "Pays-Bas", "Paesi Bassi"},
    {"NO", "Norway", "Norwegen", "Norvège", "Norvegia"},
    {"NP", "Nepal", "Nepal", "Népal", "Nepal"},
    {"NR", "Nauru", "Nauru", "Nauru", "Nauru"},
    {"NU", "Niue", "Niue", "Niue", "Niue"},
    {"NZ", "New Zealand", "Neuseeland", "Nouvelle-Zélande", "Nuova Zelanda"},
    {"OM", "Oman", "Oman", "Oman", "Oman"},
    {"PA", "Panama", "Panama", "Panama", "Panama"},
    {"PE", "Peru", "Peru", "Pérou", "Perù"},
    {"PF", "French Polynesia", "Französisch-Polynesien", "Polynésie française",
     "Polinesia francese"},
    {"PG", "Papua New Guinea", "Papua-Neuguinea", "Papouasie-Nouvelle-Guinée",
     "Papua Nuova Guinea"},
    {"PH", "Philippines", "Philippinen", "Philippines", "Filippine"},
    {"PK", "Pakistan", "Pakistan", "Pakistan", "Pakistan"},
    {"PL", "Poland", "Polen", "Pologne", "Polonia"},
    {"PM", "Saint Pierre and Miquelon", "Saint-Pierre und Miquelon", "Saint-Pierre-et-Miquelon",
     "Saint-Pierre e Miquelon"},
    {"PN", "Pitcairn", "Pitcairninseln", "Îles Pitcairn", "Isole Pitcairn"},
    {"PR", "Puerto Rico", "Puerto Rico", "Porto Rico", "Porto Rico"},
    {"PS", "Palestine", "Palästina", "Territoires palestiniens", "Palestina"},
    {"PT", "Portugal", "Portugal", "Portugal", "Portogallo"},
    {"PW", "Palau", "Palau", "Palaos", "Palau"},
    {"PY", "Paraguay", "Paraguay", "Paraguay", "Paraguay"},
    {"QA", "Qatar", "Katar", "Qatar", "Qatar"},
    {"RE", "Réunion", "Réunion", "La Réunion", "Riunione"},
    {"RO", "Romania", "Rumänien", "Roumanie", "Romania"},
    {"RS", "Serbia", "Serbien", "Serbie", "Serbia"},
    {"RU", "Russia", "Russland", "Russie", "Russia"},
    {"RW", "Rwanda", "Ruanda", "Rwanda", "Ruanda"},
    {"SA", "Saudi Arabia", "Saudi-Arabien", "Arabie saoudite", "Arabia Saudita"},
    {"SB", "Solomon Islands", "Salomonen", "Îles Salomon", "Isole Salomone"},
    {"SC", "Seychelles", "Seychellen", "Seychelles", "Seychelles"},
    {"SD", "Sudan", "Sudan", "Soudan", "Sudan"},
    {"SE", "Sweden", "Schweden", "Suède", "Svezia"},
    {"SG", "Singapore", "Singapur", "Singapour", "Singapore"},
    {"SH", "Saint Helena, Ascension and Tristan da Cunha",
     "St. Helena, Ascension und Tristan da Cunha", "Sainte-Hélène", "Sant'Elena"},
    {"SI", "Slovenia", "Slowenien", "Slovénie", "Slovenia"},
    {"SJ", "Svalbard and Jan Mayen", "Svalbard und Jan Mayen", "Svalbard et Jan Mayen",
     "Svalbard e Jan Mayen"},
    {"SK", "Slovakia", "Slowakei", "Slovaquie", "Slovacchia"},
    {"SL", "Sierra Leone", "Sierra Leone", "Sierra Leone", "Sierra Leone"},
    {"SM", "San Marino", "San Marino", "Saint-Marin", "San Marino"},
    {"SN", "Senegal", "Senegal", "Sénégal", "Senegal"},
    {"SO", "Somalia", "Somalia", "Somalie", "Somalia"},
    {"SR", "Suriname", "Suriname", "Suriname", "Suriname"},
    {"SS", "South Sudan", "Südsudan", "Soudan du Sud", "Sud Sudan"},
    {"ST", "Sao Tome and Principe", "São Tomé und Príncipe", "Sao Tomé-et-Principe",
     "São Tomé e Príncipe"},
    {"SV", "El Salvador", "El Salvador", "Salvador", "El Salvador"},
    {"SX", "Sint Maarten (Dutch part)", "Sint Maarten (niederländischer Teil)",
     "Saint-Martin (partie néerlandaise)", "Sint Maarten"},
    {"SY", "Syria", "Syrien", "Syrie", "Siria"},
    {"SZ", "Eswatini", "Eswatini", "Eswatini", "Eswatini"},
    {"TC", "Turks and Caicos Islands", "Turks- und Caicosinseln", "Îles Turques-et-Caïques",
     "Isole Turks e Caicos"},
    {"TD", "Chad", "Tschad", "Tchad", "Ciad"},
    {"TF", "French Southern Territories", "Französische Süd- und Antarktisgebiete",
     "Terres australes françaises", "Terre australi francesi"},
    {"TG", "Togo", "Togo", "Togo", "Togo"},
    {"TH", "Thailand", "Thailand", "Thaïlande", "Thailandia"},
    {"TJ", "Tajikistan", "Tadschikistan", "Tadjikistan", "Tagikistan"},
    {"TK", "Tokelau", "Tokelau", "Tokelau", "Tokelau"},
    {"TL", "Timor-Leste", "Timor-Leste", "Timor oriental", "Timor Est"},
    {"TM", "Turkmenistan", "Turkmenistan", "Turkménistan", "Turkmenistan"},
    {"TN", "Tunisia", "Tunesien", "Tunisie", "Tunisia"},
    {"TO", "Tonga", "Tonga", "Tonga", "Tonga"},
    {"TR", "Türkiye", "Türkei", "Turquie", "Turchia"},
    {"TT", "Trinidad and Tobago", "Trinidad und Tobago", "Trinité-et-Tobago",
     "Trinidad e Tobago"},
    {"TV", "Tuvalu", "Tuvalu", "Tuvalu", "Tuvalu"},
    {"TW", "Taiwan", "Taiwan", "Taïwan", "Taiwan"},
    {"TZ", "Tanzania", "Tansania", "Tanzanie", "Tanzania"},
    {"UA", "Ukraine", "Ukraine", "Ukraine", "Ucraina"},
    {"UG", "Uganda", "Uganda", "Ouganda", "Uganda"},
    {"UM", "United States Minor Outlying Islands", "Amerikanische Überseeinseln",
     "Îles mineures éloignées des États-Unis", "Isole minori esterne degli Stati Uniti"},
    {"US", "United States", "Vereinigte Staaten", "États-Unis", "Stati Uniti"},
    {"UY", "Uruguay", "Uruguay", "Uruguay", "Uruguay"},
    {"UZ", "Uzbekistan", "Usbekistan", "Ouzbékistan", "Uzbekistan"},
    {"VA", "Vatican City", "Vatikanstadt", "État de la Cité du Vatican", "Città del Vaticano"},
    {"VC", "Saint Vincent and the Grenadines", "St. Vincent und die Grenadinen",
     "Saint-Vincent-et-les Grenadines", "Saint Vincent e Grenadine"},
    {"VE", "Venezuela", "Venezuela", "Venezuela", "Venezuela"},
    {"VG", "Virgin Islands (British)", "Britische Jungferninseln", "Îles Vierges britanniques",
     "Isole Vergini britanniche"},
    {"VI", "Virgin Islands (U.S.)", "Amerikanische Jungferninseln", "Îles Vierges des États-Unis",
     "Isole Vergini americane"},
    {"VN", "Vietnam", "Vietnam", "Viêt Nam", "Vietnam"},
    {"VU", "Vanuatu", "Vanuatu", "Vanuatu", "Vanuatu"},
    {"WF", "Wallis and Futuna", "Wallis und Futuna", "Wallis-et-Futuna", "Wallis e Futuna"},
    {"WS", "Samoa", "Samoa", "Samoa", "Samoa"},
    {"YE", "Yemen", "Jemen", "Yémen", "Yemen"},
    {"YT", "Mayotte", "Mayotte", "Mayotte", "Mayotte"},
    {"ZA", "South Africa", "Südafrika", "Afrique du Sud", "Sudafrica"},
    {"ZM", "Zambia", "Sambia", "Zambie", "Zambia"},
    {"ZW", "Zimbabwe", "Simbabwe", "Zimbabwe", "Zimbabwe"}
  ]

  # Fast lookup by code, and the ordered list of codes, both built at compile time.
  @by_code Map.new(@countries, fn {code, en, de, fr, it} ->
             {code, %{en: en, de: de, fr: fr, it: it}}
           end)
  @codes Enum.map(@countries, fn {code, _en, _de, _fr, _it} -> code end)
  @code_by_english Map.new(@countries, fn {code, en, _de, _fr, _it} -> {en, code} end)

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

  # {key, English, German, French, Italian name, codes}. The key is the acronym the preset
  # button shows and is deliberately not translated: EU / EMEA / MENA / APAC are
  # the words a recruiter writes in either language. Codes are stored sorted, so
  # `region_for/1` can compare a selection against them directly.
  @regions [
    {"EU", "European Union", "Europäische Union", "Union européenne", "Unione europea",
     Enum.sort(@eu)},
    {"EMEA", "Europe, Middle East and Africa", "Europa, Naher Osten und Afrika",
     "Europe, Moyen-Orient et Afrique", "Europa, Medio Oriente e Africa",
     Enum.sort(Enum.uniq(@europe ++ @middle_east ++ @africa))},
    {"MENA", "Middle East and North Africa", "Naher Osten und Nordafrika",
     "Moyen-Orient et Afrique du Nord", "Medio Oriente e Nord Africa", Enum.sort(@mena)},
    {"APAC", "Asia-Pacific", "Asien-Pazifik", "Asie-Pacifique", "Asia-Pacifico", Enum.sort(@apac)}
  ]

  # A region naming a code this module does not know is a typo, and a typo here
  # is a preset that silently drops a country. Fail the build on it.
  for {key, _en, _de, _fr, _it, codes} <- @regions, code <- codes do
    unless Map.has_key?(@by_code, code) do
      raise "Vutuv.Countries: region #{key} lists unknown country code #{inspect(code)}"
    end
  end

  @region_codes Map.new(@regions, fn {key, _en, _de, _fr, _it, codes} -> {key, codes} end)

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
  The localized display name for a country stored by its **English** name,
  which is how `addresses.country` holds it
  (`VutuvWeb.AddressHTML.country_options/1`).

  A name outside the ISO list (an older import's "Burma") comes back as it is
  stored, so a row never loses its country; `nil` stays `nil`.
  """
  @spec localize_english_name(String.t() | nil, String.t() | atom() | nil) :: String.t() | nil
  def localize_english_name(english, locale \\ nil)

  def localize_english_name(english, locale) when is_binary(english) do
    case Map.fetch(@code_by_english, english) do
      {:ok, code} -> name(code, locale)
      :error -> english
    end
  end

  def localize_english_name(english, _locale), do: english

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
    |> Enum.map(fn {code, en, de, fr, it} ->
      {localized(resolved, en, de, fr, it), code}
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

    Enum.map(@regions, fn {key, en, de, fr, it, codes} ->
      %{key: key, name: localized(resolved, en, de, fr, it), count: length(codes)}
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

    Enum.find_value(@regions, fn {key, _en, _de, _fr, _it, region_codes} ->
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
  defp localized(:de, _en, de, _fr, _it), do: de
  defp localized(:fr, _en, _de, fr, _it), do: fr
  defp localized(:it, _en, _de, _fr, it), do: it
  defp localized(_locale, en, _de, _fr, _it), do: en

  defp normalize_locale(:de), do: :de
  defp normalize_locale(:en), do: :en
  defp normalize_locale(:fr), do: :fr
  defp normalize_locale(:it), do: :it
  defp normalize_locale("de"), do: :de
  defp normalize_locale("en"), do: :en
  defp normalize_locale("fr"), do: :fr
  defp normalize_locale("it"), do: :it

  defp normalize_locale(nil) do
    case Gettext.get_locale(VutuvWeb.Gettext) do
      "de" -> :de
      "fr" -> :fr
      "it" -> :it
      _other -> :en
    end
  end

  defp normalize_locale(_other), do: :en
end
