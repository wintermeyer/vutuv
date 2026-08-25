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

  # `lib/vutuv/cldr.ex` is the one allowed literal: `use Cldr` needs the list at
  # COMPILE time to generate its backend modules, and each locale also needs a
  # data file committed under `priv/cldr/locales/`, so it cannot follow runtime
  # config. That makes it a real coupling, which the next test checks rather
  # than leaving to whoever adds a fourth locale.
  @compile_time_literals ["lib/vutuv/cldr.ex"]

  test "no source freezes the locale list into a literal" do
    offenders =
      for path <- sources(),
          path != @owner,
          path not in @compile_time_literals,
          line <- String.split(File.read!(path), "\n"),
          line =~ ~r/~w\(en de\b|"en", "de"|Preferred-Languages: [a-z]{2},/,
          do: "#{path}: #{String.trim(line)}"

    assert offenders == [],
           "this list goes stale the moment a locale is added, and was never " <>
             "right on another installation:\n" <> Enum.join(offenders, "\n")
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
