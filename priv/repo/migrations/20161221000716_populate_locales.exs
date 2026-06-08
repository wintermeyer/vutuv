defmodule Vutuv.Repo.Migrations.PopulateLocales do
  use Ecto.Migration

  # Self-contained data migration: inserts the supported locales directly via SQL rather
  # than through Vutuv.Locale (reorganized into Vutuv.Accounts.Locale during the refactor).
  # Data migrations must not depend on application schema modules, since those modules can
  # change or be removed after the migration has shipped.

  @locales [
    {"Afaraf", "aa"},
    {"Afrikaans", "af"},
    {"Akan", "ak"},
    {"Shqip", "sq"},
    {"አማርኛ", "am"},
    {"العربية", "ar"},
    {"Aragonés", "an"},
    {"Հայերեն", "hy"},
    {"অসমীয়া", "as"},
    {"Магӏарул мацӏ", "av"},
    {"Avesta", "ae"},
    {"Aymar aru", "ay"},
    {"Azərbaycan dili", "az"},
    {"Bamanankan", "bm"},
    {"башҡорт теле", "ba"},
    {"Euskara", "eu"},
    {"беларуская мова", "be"},
    {"বাংলা", "bn"},
    {"भोजपुरी", "bh"},
    {"Bislama", "bi"},
    {"Bosanski jezik", "bs"},
    {"Brezhoneg", "br"},
    {"български език", "bg"},
    {"ဗမာစာ", "my"},
    {"Català", "ca"},
    {"Chamoru", "ch"},
    {"нохчийн мотт", "ce"},
    {"chiCheŵa", "ny"},
    {"中文", "zh"},
    {"чӑваш чӗлхи", "cv"},
    {"Kernewek", "kw"},
    {"Corsu", "co"},
    {"ᓀᐦᐃᔭᐍᐏᐣ", "cr"},
    {"Hrvatski jezik", "hr"},
    {"čeština", "cs"},
    {"Dansk", "da"},
    {"ދިވެހި", "dv"},
    {"Nederlands", "nl"},
    {"རྫོང་ཁ", "dz"},
    {"English", "en"},
    {"Esperanto", "eo"},
    {"eesti", "et"},
    {"Eʋegbe", "ee"},
    {"føroyskt", "fo"},
    {"vosa Vakaviti", "fj"},
    {"suomi", "fi"},
    {"français", "fr"},
    {"Fulfulde", "ff"},
    {"galego", "gl"},
    {"ქართული", "ka"},
    {"Deutsch", "de"},
    {"ελληνικά", "el"},
    {"Avañe'ẽ", "gn"},
    {"ગુજરાતી", "gu"},
    {"Kreyòl ayisyen", "ht"},
    {"هَوُسَ", "ha"},
    {"עברית", "he"},
    {"Otjiherero", "hz"},
    {"हिन्दी", "hi"},
    {"Hiri Motu", "ho"},
    {"magyar", "hu"},
    {"Interlingua", "ia"},
    {"Bahasa Indonesia", "id"},
    {"Interlingue", "ie"},
    {"Gaeilge", "ga"},
    {"Asụsụ Igbo", "ig"},
    {"Iñupiaq", "ik"},
    {"Ido", "io"},
    {"Íslenska", "is"},
    {"italiano", "it"},
    {"ᐃᓄᒃᑎᑐᑦ", "iu"},
    {"日本語", "ja"},
    {"Basa Jawa", "jv"},
    {"kalaallisut", "kl"},
    {"ಕನ್ನಡ", "kn"},
    {"Kanuri", "kr"},
    {"كشميري‎", "ks"},
    {"қазақ тілі", "kk"},
    {"ភាសាខ្មែរ", "km"},
    {"Gĩkũyũ", "ki"},
    {"Ikinyarwanda", "rw"},
    {"Кыргызча", "ky"},
    {"коми кыв", "kv"},
    {"Kikongo", "kg"},
    {"한국어", "ko"},
    {"كوردی‎", "ku"},
    {"Kuanyama", "kj"},
    {"latine", "la"},
    {"Lëtzebuergesch", "lb"},
    {"Luganda", "lg"},
    {"Limburgs", "li"},
    {"Lingála", "ln"},
    {"ພາສາລາວ", "lo"},
    {"lietuvių kalba", "lt"},
    {"Tshiluba", "lu"},
    {"latviešu valoda", "lv"},
    {"Gaelg", "gv"},
    {"македонски јазик", "mk"},
    {"fiteny malagasy", "mg"},
    {"بهاس ملايو‎", "ms"},
    {"മലയാളം", "ml"},
    {"Malti", "mt"},
    {"te reo Māori", "mi"},
    {"मराठी", "mr"},
    {"Kajin M̧ajeļ", "mh"},
    {"Монгол хэл", "mn"},
    {"Dorerin Naoero", "na"},
    {"Diné bizaad", "nv"},
    {"isiNdebele", "nd"},
    {"नेपाली", "ne"},
    {"Owambo", "ng"},
    {"Norsk bokmål", "nb"},
    {"Norsk nynorsk", "nn"},
    {"Norsk", "no"},
    {"ꆈꌠ꒿ Nuosuhxop", "ii"},
    {"isiNdebele", "nr"},
    {"occitan", "oc"},
    {"ᐊᓂᔑᓈᐯᒧᐎᓐ", "oj"},
    {"ѩзыкъ словѣньскъ", "cu"},
    {"Afaan Oromoo", "om"},
    {"ଓଡ଼ିଆ", "or"},
    {"ирон æвзаг", "os"},
    {"ਪੰਜਾਬੀ", "pa"},
    {"पाऴि", "pi"},
    {"فارسی", "fa"},
    {"polski", "pl"},
    {"پښتو", "ps"},
    {"Português", "pt"},
    {"Runa Simi", "qu"},
    {"rumantsch grischun", "rm"},
    {"Ikirundi", "rn"},
    {"Română", "ro"},
    {"Русский", "ru"},
    {"संस्कृतम्", "sa"},
    {"sardu", "sc"},
    {"سنڌي، سندھی‎", "sd"},
    {"Davvisámegiella", "se"},
    {"gagana fa'a Samoa", "sm"},
    {"yângâ tî sängö", "sg"},
    {"српски језик", "sr"},
    {"Gàidhlig", "gd"},
    {"chiShona", "sn"},
    {"සිංහල", "si"},
    {"slovenčina", "sk"},
    {"slovenski jezik", "sl"},
    {"Soomaaliga", "so"},
    {"Sesotho", "st"},
    {"español", "es"},
    {"Basa Sunda", "su"},
    {"Kiswahili", "sw"},
    {"SiSwati", "ss"},
    {"svenska", "sv"},
    {"தமிழ்", "ta"},
    {"తెలుగు", "te"},
    {"тоҷикӣ", "tg"},
    {"ไทย", "th"},
    {"ትግርኛ", "ti"},
    {"བོད་ཡིག", "bo"},
    {"Түркмен", "tk"},
    {"Wikang Tagalog", "tl"},
    {"Setswana", "tn"},
    {"faka Tonga", "to"},
    {"Türkçe", "tr"},
    {"Xitsonga", "ts"},
    {"Татарча / Tatarça", "tt"},
    {"Twi", "tw"},
    {"Reo Tahiti", "ty"},
    {"ئۇيغۇرچە‎", "ug"},
    {"Українська", "uk"},
    {"اردو", "ur"},
    {"أۇزبېك‎", "uz"},
    {"Tshivenḓa", "ve"},
    {"Tiếng Việt", "vi"},
    {"Volapük", "vo"},
    {"walon", "wa"},
    {"Cymraeg", "cy"},
    {"Wollof", "wo"},
    {"Frysk", "fy"},
    {"isiXhosa", "xh"},
    {"ייִדיש", "yi"},
    {"Yorùbá", "yo"},
    {"Vahcuengh", "za"},
    {"isiZulu", "zu"}
  ]

  def up do
    # The repo now defaults every migration's primary key to :binary_id
    # (config/config.exs), so on a from-scratch build the locales.id column is a
    # UUID with no DB default and this raw INSERT must supply one. Mint a v7 id
    # per row in SQL — self-contained (no app modules, per the note above), the
    # same generator the convert_ids_to_uuid_v7 migration uses. The pg_temp
    # function is session-local and auto-dropped. On a real upgrade these rows
    # already exist under their original ids; this path only runs for a
    # from-scratch DB (CI, a fresh dev clone).
    execute("""
    CREATE FUNCTION pg_temp.vutuv_uuid_v7_now() RETURNS uuid AS $$
      SELECT encode(
        set_bit(
          set_bit(
            overlay(uuid_send(gen_random_uuid())
                    placing substring(int8send((floor(extract(epoch FROM now()) * 1000))::bigint) from 3)
                    from 1 for 6),
            52, 1),
          53, 1),
        'hex')::uuid
    $$ LANGUAGE sql VOLATILE
    """)

    values =
      @locales
      |> Enum.map(fn {endonym, code} ->
        "(pg_temp.vutuv_uuid_v7_now(), #{quote_sql(code)}, #{quote_sql(endonym)}, NOW(), NOW())"
      end)
      |> Enum.join(", ")

    execute("INSERT INTO locales (id, value, endonym, inserted_at, updated_at) VALUES " <> values)
  end

  def down do
    execute("DELETE FROM locales")
  end

  defp quote_sql(string) do
    escaped =
      string
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "''")

    "'" <> escaped <> "'"
  end
end
