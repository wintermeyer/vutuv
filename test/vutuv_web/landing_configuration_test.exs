defmodule VutuvWeb.LandingConfigurationTest do
  @moduledoc """
  The landing page's per-installation switches: which profile its questions
  point at as the example, where it says the data lives, whether it asks the
  Fediverse question at all, and whether it shows the teaser video.

  Keys flipped here, and who else reads them (the rule below wants this named,
  so a widened blast radius is visible at a glance): `:landing_example_profile_url`
  and `:data_location` are read only by `VutuvWeb.PageHTML`; `:landing_teaser_video` by
  `VutuvWeb.Teaser` (the start page and the investor page); `:ads_enabled` by
  `VutuvWeb.AdServing` and the `/system/ads` routes; `:fediverse_enabled` by
  `Vutuv.Fediverse.enabled?/0`, which the tag timeline, the feed source tabs and
  the sign-up form all consult.

  async: false, like `VutuvWeb.AdsDisabledTest`: every test here flips a global
  application env that the SQL sandbox does not roll back, so it must not run
  beside a test that reads the same flag. That is not theory — `:fediverse_enabled` is read
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

  # vutuv is a German site and ConnTest defaults to English (the locale rule in
  # CLAUDE.md), so the German render is its own request.
  defp landing_de(conn) do
    conn |> put_req_header("accept-language", "de-DE,de") |> get(~p"/") |> html_response(200)
  end

  # /llms.txt is the agent-discovery file, and it used to list the ad page
  # unconditionally. Ads ship switched OFF, and the ad page 404s while they are,
  # so every installation was pointing agents at a dead URL.
  describe "/llms.txt lists only pages this installation actually serves" do
    test "names the ad page when ads are on", %{conn: conn} do
      put_config(:ads_enabled, true)

      body = conn |> get(~p"/llms.txt") |> response(200)

      assert body =~ "`/system/ads`"
      refute body =~ "{{ads}}"
      assert body =~ "(booking happens online and requires a login)\n\nList pages"
    end

    test "leaves it out when they are off, so it names no 404", %{conn: conn} do
      put_config(:ads_enabled, false)

      body = conn |> get(~p"/llms.txt") |> response(200)

      refute body =~ "`/system/ads`"
      refute body =~ "{{ads}}"
      # The rest of the document is untouched, blank line and indentation
      # included — the placeholder must not eat the paragraph break. Anchored on
      # whatever entry the placeholder now follows (the investor page), not on
      # the jobs line it followed when this was written.
      assert body =~ "`/jobs`"

      # Anchored on the break itself, not on the sentence before it: the locale
      # list in that sentence is `Enum.join(Languages.site_locales(), ", ")`, so
      # spelling it here made adding a language turn this test red, and deriving
      # it here would only re-implement the line under test.
      assert body =~ ")\n\nList pages paginate with `?page=N`."
    end
  end

  # Same trap one level up: the footer points at `/system/ads`, which 404s while ads
  # are off. Ads ship off, and vutuv.de runs that way today, so the
  # unconditional link shipped a dead entry in the footer of every page.
  describe "the /system/ads link follows the ad switch" do
    test "the footer offers Advertising only when the ad page exists", %{conn: conn} do
      put_config(:ads_enabled, true)
      assert conn |> get(~p"/impressum") |> html_response(200) =~ ~s|href="/system/ads"|

      put_config(:ads_enabled, false)
      refute conn |> get(~p"/impressum") |> html_response(200) =~ ~s|href="/system/ads"|
    end
  end

  describe "the landing page's installation switches" do
    # "Readable without an account" is a claim, and this is the one-click check
    # that goes with it: the answer ends on the configured profile, label
    # without the scheme, href with it.
    test "offers the configured profile as the example to look at", %{conn: conn} do
      example("https://vutuv.example/ada")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "For example:"
      assert html =~ ~s(href="https://vutuv.example/ada")
      assert html =~ ~r{>\s*vutuv\.example/ada\s*<}
      refute html =~ "vutuv.de/wintermeyer"
    end

    # A configured URL may carry a trailing slash. The join lives in
    # `example_profile_url/0` so href and label cannot disagree about it, which
    # they did while the markup did the joining: `…/ada//cv` under `…/ada/cv`.
    # The CV link is gone; the API answer's Markdown example appends to the
    # same base.
    test "a trailing slash in the configured URL does not double up", %{conn: conn} do
      example("https://vutuv.example/ada/")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="https://vutuv.example/ada.md")
    end

    # The installability half of the same knob. Asserted on the answer's tail,
    # not on the URL: the founder signature in the hero links to a profile too,
    # so a bare URL match would pass for the wrong reason.
    test "drops the example and its Markdown sibling where the URL is cleared", %{conn: conn} do
      example("")

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "For example:"
      refute html =~ "vutuv.de/wintermeyer"
      # The questions stay: their claims hold on every installation.
      assert html =~ "without signing up?"
      assert html =~ "Is there an API?"
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
    # question 404s there, so promising Mastodon on the operator's front page
    # would be a straight lie. The sign-up form already gates its Fediverse
    # question the same way.
    test "hides the Fediverse question where the installation federates nothing", %{conn: conn} do
      put_config(:fediverse_enabled, false)

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "Fediverse"
      refute html =~ "Mastodon"
      # The other questions are untouched.
      refute html =~ ~s(data-landing-faq-entry="fediverse")
      assert html =~ ~s(data-landing-faq-entry="open_source")
    end

    test "drops only the hosting claim where the operator cleared it", %{conn: conn} do
      put_config(:data_location, "")

      html = landing_de(conn)

      refute html =~ "eigenen Servern in"
      refute html =~ "fremden Cloud"
      # The software's own promise is not the operator's to lose.
      assert html =~ "Wo liegen meine Daten?"
      assert html =~ "ein einziges Cookie"
    end

    test "names the place the operator configured", %{conn: conn} do
      put_config(:data_location, "Österreich")

      html = landing_de(conn)

      assert html =~ "eigenen Servern in Österreich"
      refute html =~ "eigenen Servern in Deutschland"
    end

    # An installation that does not want the vutuv.de teaser on its start page
    # switches it off, and the hero keeps its three claims without it.
    test "drops the teaser video where the installation switched it off", %{conn: conn} do
      put_config(:landing_teaser_video, true)
      assert conn |> get(~p"/") |> html_response(200) =~ "landing-teaser"

      put_config(:landing_teaser_video, false)
      html = build_conn() |> get(~p"/") |> html_response(200)
      refute html =~ "landing-teaser"
      assert html =~ "data-hero-points"
    end

    # The investor page shows and hands out the same films, so the same switch
    # takes them off there too, from the page and from its agent formats.
    test "drops the teaser from the investor page where it is switched off", %{conn: conn} do
      put_config(:landing_teaser_video, false)

      refute conn |> get(~p"/system/investors") |> html_response(200) =~ "investors-teaser"

      refute build_conn() |> get(~p"/system/investors" <> ".md") |> response(200) =~
               "vutuv-teaser-"
    end
  end
end
