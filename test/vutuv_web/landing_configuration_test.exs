defmodule VutuvWeb.LandingConfigurationTest do
  @moduledoc """
  The landing page's per-installation switches: which profile it offers as
  "try it out", where it says the data lives, and whether it mentions the
  Fediverse at all.

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
      # included — the placeholder must not eat the paragraph break.
      assert body =~ "`/jobs`"
      assert body =~ "how to apply\n\nList pages paginate with `?page=N`."
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
      assert html =~ ">\n        vutuv.example/ada\n      <"
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

    test "drops only the hosting claim where the operator cleared it", %{conn: conn} do
      put_config(:data_location, "")

      html =
        conn |> put_req_header("accept-language", "de-DE,de") |> get(~p"/") |> html_response(200)

      refute html =~ "eigenen Servern"
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
