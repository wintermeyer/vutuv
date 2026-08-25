defmodule Vutuv.SiteLocalesChokepointTest do
  @moduledoc """
  `Vutuv.Languages.site_locales/0` is the one reader of which locales this
  installation serves. Its own doc says so, and the list still grew copies:
  five modules re-derived it from the Endpoint config by hand (each with its own
  comment about the same trap), and three more had frozen it into source —
  `Preferred-Languages: en, de` in `security.txt`, `~w(en de it)` as a module
  attribute, and two hardcoded `<option>`s in the job-posting form.

  Two of those were already **wrong** against the shipped Italian: a job posting
  in Italian passed the changeset and could not be picked in the form, and
  security.txt told a researcher we do not read Italian.

  This is a grep test, and a grep test is only as good as its calibration —
  every pattern here was run against the un-fixed tree and matched.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Languages

  @owner "lib/vutuv/languages.ex"

  defp sources do
    Path.wildcard("lib/**/*.ex") ++ Path.wildcard("lib/**/*.heex")
  end

  test "nothing but the owner reads :locales out of the Endpoint config" do
    offenders =
      for path <- sources(),
          path != @owner,
          line <- String.split(File.read!(path), "\n"),
          line =~ ~r/config\[:locales\]|Keyword\.get\(.*:locales/,
          do: "#{path}: #{String.trim(line)}"

    assert offenders == [],
           "read the locale list through Languages.site_locales/0 instead:\n" <>
             Enum.join(offenders, "\n")
  end

  # Two files are allowed to hold the list as a COMPILE-TIME literal, because
  # each locale needs a committed file that the module reads while compiling:
  # `cldr.ex` (its backend modules, plus `priv/cldr/locales/<code>.json`) and
  # `help_controller.ex` (`priv/help/<page>_<locale>.md`, via
  # `@external_resource`). Neither can follow runtime config. Both are real
  # couplings, so the two tests below check them instead of trusting whoever
  # adds a fourth locale to remember.
  @compile_time_literals ["lib/vutuv/cldr.ex", "lib/vutuv_web/controllers/help_controller.ex"]

  # Matches a list **assigned as the served locales**, in either order — the
  # first version of this pattern read `~w\(en de` and so could not see
  # `help_controller.ex`'s `~w(de en it)`. A grep guard that reports a clean
  # tree because the copy is spelled in a different order is worse than no
  # guard, since it is believed.
  #
  # Deliberately keyed on the *assignment*, not on the codes appearing anywhere:
  # `Gettext.get_locale(…) in ~w(de it)` picks a decimal separator, which is a
  # different question with a different answer per locale, and matching it here
  # would drown the real hazard in noise.
  @literal_list ~r/(@\w*locales?\s*=?\s*~w\(|locales:\s*\[")|Preferred-Languages: [a-z]{2},/

  test "no source freezes the locale list into a literal" do
    offenders =
      for path <- sources(),
          path != @owner,
          path not in @compile_time_literals,
          line <- String.split(File.read!(path), "\n"),
          line =~ @literal_list,
          do: "#{path}: #{String.trim(line)}"

    assert offenders == [],
           "this list goes stale the moment a locale is added, and was never " <>
             "right on another installation:\n" <> Enum.join(offenders, "\n")
  end

  test "the pattern really sees both orders, and not the decimal separator" do
    assert "  @locales ~w(de en it)" =~ @literal_list
    assert "  @locales ~w(en de)" =~ @literal_list
    assert ~S(    locales: ["en", "de", "it"],) =~ @literal_list
    refute "  @locales Languages.site_locales()" =~ @literal_list
    refute ~S[    if Gettext.get_locale(x) in ~w(de it), do: ",", else: "."] =~ @literal_list
  end

  test "every served locale has a help page for every help topic" do
    missing =
      for page <- ~w(markdown mastodon),
          locale <- Languages.site_locales(),
          not File.exists?(Path.join("priv/help", "#{page}_#{locale}.md")),
          do: "priv/help/#{page}_#{locale}.md"

    assert missing == [],
           "the help controller falls back to English for a locale with no file, " <>
             "silently. Write these:\n" <> Enum.join(missing, "\n")
  end

  test "the CLDR backend covers every locale the installation serves" do
    # Compiled in, so ask the backend rather than re-reading the source: a
    # served locale CLDR does not know raises at the first flag emoji.
    known = Vutuv.Cldr.known_locale_names() |> Enum.map(&to_string/1)

    missing = Enum.reject(Languages.site_locales(), &(&1 in known))

    assert missing == [],
           "Vutuv.Cldr must list #{inspect(missing)} too — compile once with " <>
             "network access and commit priv/cldr/locales/<code>.json"
  end

  test "the owner answers the configured list" do
    locales = Languages.site_locales()

    assert is_list(locales) and locales != []
    assert "en" in locales

    # Every configured locale must have a display name, since the job form and
    # the composer's select now build their options from this list.
    for code <- locales do
      assert is_binary(Languages.name(code))
      refute Languages.name(code) == String.upcase(code), "no name for #{code}"
    end
  end
end
