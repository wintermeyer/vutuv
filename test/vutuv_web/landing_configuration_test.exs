defmodule VutuvWeb.LandingConfigurationTest do
  @moduledoc """
  The landing page's per-installation switches: which profile it offers as
  "try it out", where it says the data lives, whether it mentions the Fediverse
  at all, and whether it offers the Arbeitszeugnis review.

  Keys flipped here, and who else reads them (the rule below wants this named,
  so a widened blast radius is visible at a glance): `:landing_example_profile_url`
  and `:data_location` are read only by `VutuvWeb.PageHTML`; `:ads_enabled` by
  `VutuvWeb.Plug.AdBanner` and the `/ads` routes; `:fediverse_enabled` by
  `Vutuv.Fediverse.enabled?/0`, which the tag timeline, the feed source tabs and
  the sign-up form all consult; `:reference_checks_enabled` by
  `Vutuv.References.Checks.enabled?/0`, which gates `Vutuv.References.CheckWorker`,
  `VutuvWeb.ReferenceCheckLive` and `VutuvWeb.JobReferenceHTML.checks_enabled?/0`.

  async: false, like `VutuvWeb.LandingExperimentDisabledTest` and
  `VutuvWeb.AdsDisabledTest`: every test here flips a global application env
  that the SQL sandbox does not roll back, so it must not run beside a test
  that reads the same flag. That is not theory — `:fediverse_enabled` is read
  by `Vutuv.Tags.Timeline.remote_posts_query/1`, and with these tests left in
  an async module the tag timeline's fediverse total intermittently came back
  as 0 while this file happened to have federation switched off.
  """
  use VutuvWeb.ConnCase

  # Restores exactly what was there, which `put_env(key, original)` cannot do:
  # `get_env` answers `nil` both for "absent" and for "present as nil", so if a
  # test that ran earlier had deleted the key, the naive restore writes `nil`
  # back as a real value. `Vutuv.Fediverse.enabled?/0` then returns `nil`
  # instead of falling through to its `true` default, and every `and` on it
  # raises BadBooleanError — 95 unrelated tests went down that way before this
  # helper existed (2026-08-01). `fetch_env/2` tells the two cases apart.
  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp example(url), do: put_config(:landing_example_profile_url, url)

  # /llms.txt is the agent-discovery file, and it used to list `/ads`
  # unconditionally. Ads ship switched OFF, and the ad page 404s while they are,
  # so every installation was pointing agents at a dead URL.
  describe "/llms.txt lists only pages this installation actually serves" do
    test "names the ad page when ads are on", %{conn: conn} do
      put_config(:ads_enabled, true)

      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "`/ads`"
      refute body =~ "{{ads}}"
      assert body =~ "(booking happens online and requires a login)\n\nList pages"
    end

    test "leaves it out when they are off, so it names no 404", %{conn: conn} do
      put_config(:ads_enabled, false)

      body = conn |> get(~p"/llms.txt") |> response(200)

      refute body =~ "`/ads`"
      refute body =~ "{{ads}}"
      # The rest of the document is untouched, blank line and indentation
      # included — the placeholder must not eat the paragraph break. Anchored on
      # whatever entry the placeholder now follows (the investor page), not on
      # the jobs line it followed when this was written.
      assert body =~ "`/jobs`"
      assert body =~ "(English only)\n\nList pages paginate with `?page=N`."
    end
  end

  # Same trap one level up: the footer points at `/ads`, which 404s while ads
  # are off. Ads ship off, and vutuv.de runs that way today, so the
  # unconditional link shipped a dead entry in the footer of every page.
  describe "the /ads link follows the ad switch" do
    test "the footer offers Advertising only when the ad page exists", %{conn: conn} do
      put_config(:ads_enabled, true)
      assert conn |> get(~p"/impressum") |> html_response(200) =~ ~s|href="/ads"|

      put_config(:ads_enabled, false)
      refute conn |> get(~p"/impressum") |> html_response(200) =~ ~s|href="/ads"|
    end
  end

  describe "the landing page's installation switches" do
    # "Readable without an account" is a claim, and this is the one-click check
    # that goes with it. The label drops the scheme, the href keeps it.
    test "offers a real profile to try out", %{conn: conn} do
      example("https://vutuv.example/ada")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Try it out:"
      assert html =~ ~s(href="https://vutuv.example/ada")
      assert html =~ ~r{>\s*vutuv\.example/ada\s*<}
    end

    # The CV builder is public, so the same one-click check applies to it, and it
    # hangs off the same setting: `/cv` under the configured profile.
    test "offers that profile's CV builder too", %{conn: conn} do
      example("https://vutuv.example/ada")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="https://vutuv.example/ada/cv")
      assert html =~ ~r{>\s*vutuv\.example/ada/cv\s*<}
    end

    # A configured URL may carry a trailing slash. The join lives in
    # `example_profile_url/1` so href and label cannot disagree about it, which
    # they did while the markup did the joining: `…/ada//cv` under `…/ada/cv`.
    test "a trailing slash in the configured URL does not double up", %{conn: conn} do
      example("https://vutuv.example/ada/")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="https://vutuv.example/ada/cv")
      refute html =~ "ada//cv"
    end

    # The installability half of the same knob. Asserted on the line itself, not
    # on the URL: the founder signature in the hero links to a profile too, so a
    # bare URL match would pass for the wrong reason.
    test "drops the try-it-out line where the installation cleared the URL", %{conn: conn} do
      example("")

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "Try it out:"
      # The screenshots and the rest of the section stay.
      assert html =~ "data-profile-shots"
      assert html =~ "data-landing-features"
      # The per-profile chips go with it; the installation-wide one remains.
      refute html =~ "vutuv.de/wintermeyer.md"
      assert html =~ ~s(href="/llms.txt")
    end

    # The founder signature in the hero linked to `https://vutuv.de/wintermeyer`
    # written out in the markup, past the very key whose config comment names
    # this page. So a third-party installation's start page pointed at a profile
    # on vutuv.de, and an operator who had cleared the key kept the link here
    # while the 404 page correctly dropped its own. The *name* stays written in
    # the template — that is an attribution, not a setting.
    test "the founder signature links to the configured profile", %{conn: conn} do
      example("https://vutuv.example/ada")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="https://vutuv.example/ada")
      refute html =~ "vutuv.de/wintermeyer"
      assert html =~ "Stefan Wintermeyer"
    end

    test "and renders the name unlinked where the installation cleared the URL", %{conn: conn} do
      example("")

      html = conn |> get(~p"/") |> html_response(200)

      # The attribution survives; only the link into somebody else's site goes.
      assert html =~ "Stefan Wintermeyer"
      refute html =~ "vutuv.de/wintermeyer"
    end

    # The /username helper page offers the same example and had spelled the
    # vutuv.de founder profile out in its markup, so an installation that
    # configured its own — or cleared it — still sent people to vutuv.de.
    test "the /username helper page offers the configured example too", %{conn: conn} do
      example("https://vutuv.example/ada")

      html = conn |> get(~p"/username") |> response(404)

      assert html =~ "https://vutuv.example/ada"
      assert html =~ "vutuv.example/ada"
      refute html =~ "vutuv.de/wintermeyer"
    end

    test "and drops the example line where the installation cleared the URL", %{conn: conn} do
      example("")

      html = conn |> get(~p"/username") |> response(404)

      refute html =~ "really exists"
      # The rest of the explanation stays — that is the point of the page.
      assert html =~ "only a placeholder"
    end

    # An intranet installation federates nothing: every endpoint behind that
    # section 404s there, so promising Mastodon on the operator's front page
    # would be a straight lie. The sign-up form already gates its Fediverse
    # question the same way.
    test "hides the Fediverse section where the installation federates nothing", %{conn: conn} do
      put_config(:fediverse_enabled, false)

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "data-communication-shots"
      refute html =~ "Mastodon"
      # The rest of the page is untouched.
      assert html =~ "data-profile-shots"
      assert html =~ "data-landing-features"
    end

    # The same shape as the Fediverse gate above. An installation with no model
    # behind the review queue can still store Arbeitszeugnisse, but the grading
    # this section is named after never happens there, so the heading, the
    # screenshots and the feature bullet all have to go rather than promise it.
    test "hides the reference review where the installation runs no model", %{conn: conn} do
      put_config(:reference_checks_enabled, false)

      html =
        conn |> put_req_header("accept-language", "de-DE,de") |> get(~p"/") |> html_response(200)

      refute html =~ "data-reference-shots"
      refute html =~ "Arbeitszeugnis"
      refute html =~ "landing-reference-list.avif"
      # The CV section is a different feature and stays, as does the rest.
      assert html =~ "data-career-shots"
      assert html =~ "data-profile-shots"
      assert html =~ "data-landing-features"
    end

    test "drops only the hosting claim where the operator cleared it", %{conn: conn} do
      put_config(:data_location, "")

      html =
        conn |> put_req_header("accept-language", "de-DE,de") |> get(~p"/") |> html_response(200)

      # Named by the card, not by the bare phrase "eigenen Servern": the
      # Arbeitszeugnis section promises our own servers too, and that promise
      # hangs off the review switch rather than off :data_location, so a
      # substring refute would fail for a claim this test is not about.
      refute html =~ "Wo Ihre Daten liegen"
      refute html =~ "eigenen Servern in"
      # The software's own promises are not the operator's to lose.
      assert html =~ "Fair und transparent"
      assert html =~ "Cookie"
    end

    test "names the place the operator configured", %{conn: conn} do
      put_config(:data_location, "Österreich")

      html =
        conn |> put_req_header("accept-language", "de-DE,de") |> get(~p"/") |> html_response(200)

      assert html =~ "eigenen Servern in Österreich"
      refute html =~ "eigenen Servern in Deutschland"
    end

    # The machine-format chips hang off that same profile, so one setting moves
    # both and the claim above them can be checked against a real document.
    test "the machine-format chips point at that same profile, RSS included", %{conn: conn} do
      example("https://vutuv.example/ada")

      html = conn |> get(~p"/") |> html_response(200)

      for suffix <- ~w(.md .txt .json .xml .vcf) do
        assert html =~ ~s(href="https://vutuv.example/ada#{suffix}")
      end

      # From VutuvWeb.Feeds, so the chip cannot drift from the real feed route.
      assert html =~
               ~s(href="https://vutuv.example/ada#{VutuvWeb.Feeds.user_feed_suffix()}")

      # Installation-wide, so it survives a cleared example profile.
      assert html =~ ~s(href="/llms.txt")
    end
  end
end
