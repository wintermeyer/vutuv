defmodule Vutuv.CldrLocaleBundleTest do
  @moduledoc """
  Guards the offline build (issue #1545) — see `Vutuv.Cldr`'s doc for the
  mechanism.
  """
  use ExUnit.Case, async: true

  @locales_dir "priv/cldr/locales"

  test "the backend reads locale data from the app's own priv, not ex_cldr's" do
    assert Vutuv.Cldr.__cldr__(:config).data_dir == Application.app_dir(:vutuv, "priv/cldr")
  end

  test "no configured locale gives Cldr.Install a reason to download" do
    config = Vutuv.Cldr.__cldr__(:config)

    for locale <- config.locales do
      assert Cldr.Install.locale_installed?(locale, config),
             "no locale file for #{locale} — the release build would download it " <>
               "from GitHub at compile time (issue #1545)"

      refute Cldr.Install.locale_stale?(locale, config),
             "the locale file for #{locale} is stale — Cldr.Install would re-download " <>
               "it at compile time; refresh and commit it (see Vutuv.Cldr's doc)"
    end
  end

  # A fresh checkout only has what is committed, but the checks above read
  # whatever the compile left on disk — including a file it just downloaded
  # (a new locale, or one refreshed after an ex_cldr upgrade). Only git can
  # tell the difference.
  test "the compile did not need locale data the repo does not carry" do
    {untracked, 0} =
      System.cmd("git", ["ls-files", "--others", "--exclude-standard", @locales_dir],
        cd: File.cwd!()
      )

    assert untracked == "",
           "uncommitted locale files (the compile downloaded them?): #{untracked}"

    {_, diff_status} =
      System.cmd("git", ["diff", "--quiet", "--", @locales_dir], cd: File.cwd!())

    assert diff_status == 0,
           "#{@locales_dir} differs from the committed state — the compile " <>
             "re-downloaded locale data (ex_cldr upgrade?); commit the refreshed files"
  end
end
