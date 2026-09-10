defmodule VutuvWeb.PostLive.FeedTagSourcesTest do
  @moduledoc """
  The "Where should #tag come from?" panel on the feed's tag card (issue #2128).

  A followed tag has carried sources since #2125 and has been pulling from them
  since #2126, with nothing anywhere saying so. This is the first member-facing
  control over them: a chip counting the servers, and a panel that offers the
  configured ones with their size beside them.

  `async: false`: it flips `:tag_source_servers`, `:fetch_external_tag_posts`
  and `:external_tag_req_options`, all of which are application env and
  therefore global — see the note in `Vutuv.Tags.ExternalTagClientTest`, which
  flips the same seam. The panel also refreshes through `start_async`, so the
  task needs the shared sandbox this brings.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.ExternalTagHelpers

  alias Vutuv.Sessions
  alias Vutuv.Tags
  alias Vutuv.Tags.SourceServers

  @good "troet.example"
  @locked "chaos.example"

  setup %{conn: conn} do
    put_config(:fetch_external_tag_posts, true)
    put_config(:tag_source_servers, [@good, @locked])

    stub_servers(%{
      @good => %{accounts: 49_157, active_month: 5_586, posts: 5_532_040, language: "de"},
      @locked => %{timeline: 422, language: "en"}
    })

    {conn, user} = create_and_login_user(conn)

    name = Vutuv.Factory.unique_tag_name("Koblenz")
    tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
    {:ok, follow} = Tags.follow_tag(user, tag)

    %{conn: conn, user: user, tag: tag, follow: follow, name: name}
  end

  defp open_panel(live, tag) do
    live |> element("#tag-sources-chip-#{tag.id}") |> render_click()
    # The panel draws from what is stored and fills in behind itself, so the
    # figures land with the async refresh rather than with the first render.
    render_async(live)
  end

  defp switch(host), do: "#tag-source-switch-#{String.replace(host, ".", "-")}"

  describe "the chip" do
    test "counts the servers feeding the tag", %{conn: conn, tag: tag, follow: follow} do
      {:ok, live, _html} = live(conn, ~p"/feed")

      # A fresh follow reads from this installation and nothing else.
      assert live |> element("#tag-sources-chip-#{tag.id}") |> render() =~ ">1<"

      {:ok, _row} = Tags.add_tag_follow_source(follow, @good)
      send(live.pid, {:tag_follows_changed, %{}})

      assert live |> element("#tag-sources-chip-#{tag.id}") |> render() =~ ">2<"
    end

    test "opens and closes the panel", %{conn: conn, tag: tag} do
      {:ok, live, _html} = live(conn, ~p"/feed")

      refute has_element?(live, "#tag-sources-panel")

      open_panel(live, tag)
      assert has_element?(live, "#tag-sources-panel")

      live |> element("#tag-sources-close") |> render_click()
      refute has_element?(live, "#tag-sources-panel")
    end
  end

  describe "the panel" do
    test "offers the configured servers with their size beside them", %{conn: conn, tag: tag} do
      {:ok, live, _html} = live(conn, ~p"/feed")
      html = open_panel(live, tag)

      assert html =~ @good
      assert html =~ "Hallo im Beispiel-Server!"
      assert html =~ "DE"

      # Formatted, never a run-together integer: the two figures a reader
      # compares are grouped exactly, the post count is a magnitude.
      assert html =~ "49,157"
      assert html =~ "5,586"
      assert html =~ "5M"
      refute html =~ "49157"
      refute html =~ "5532040"
    end

    test "shows this installation, on and impossible to switch off", %{conn: conn, tag: tag} do
      {:ok, live, _html} = live(conn, ~p"/feed")
      open_panel(live, tag)

      local = Tags.local_tag_follow_source()
      html = live |> element(switch(local)) |> render()

      assert html =~ ~s(aria-checked="true")
      assert html =~ "disabled"
    end

    test "refuses to remove this installation even when the event is pushed", %{
      conn: conn,
      tag: tag,
      follow: follow
    } do
      {:ok, live, _html} = live(conn, ~p"/feed")
      open_panel(live, tag)

      # The disabled attribute is a courtesy; the rule lives in the context
      # (`Tags.remove_tag_follow_source/2` refuses the local source), so the
      # event is pushed past the courtesy to reach it.
      render_click(live, "tag-source-remove", %{"source" => Tags.local_tag_follow_source()})

      assert Tags.tag_follow_sources(follow) == [Tags.local_tag_follow_source()]
      assert live |> element("#tag-sources-chip-#{tag.id}") |> render() =~ ">1<"
    end

    test "a server that only answers to members cannot be picked", %{conn: conn, tag: tag} do
      {:ok, live, _html} = live(conn, ~p"/feed")
      html = open_panel(live, tag)

      assert html =~ "only to somebody with an account there"
      assert live |> element(switch(@locked)) |> render() =~ "disabled"
    end

    test "switching a server on and off again", %{conn: conn, tag: tag, follow: follow} do
      {:ok, live, _html} = live(conn, ~p"/feed")
      open_panel(live, tag)

      live |> element(switch(@good)) |> render_click()
      assert @good in Tags.tag_follow_sources(follow)
      assert live |> element("#tag-sources-chip-#{tag.id}") |> render() =~ ">2<"

      live |> element(switch(@good)) |> render_click()
      refute @good in Tags.tag_follow_sources(follow)
      assert live |> element("#tag-sources-chip-#{tag.id}") |> render() =~ ">1<"
    end
  end

  describe "a typed address" do
    test "joins the list once it has answered", %{conn: conn, tag: tag, follow: follow} do
      stub_servers(%{"kowelenz.example" => %{language: "de"}})

      {:ok, live, _html} = live(conn, ~p"/feed")
      open_panel(live, tag)

      live |> element("#tag-source-form") |> render_submit(%{"source" => "kowelenz.example"})

      assert "kowelenz.example" in Tags.tag_follow_sources(follow)
      assert_received {:req, "kowelenz.example", "/api/v1/timelines/tag/" <> _hashtag}
    end

    test "is refused over http", %{conn: conn, tag: tag, follow: follow} do
      {:ok, live, _html} = live(conn, ~p"/feed")
      open_panel(live, tag)

      html =
        live |> element("#tag-source-form") |> render_submit(%{"source" => "http://#{@good}"})

      assert html =~ "Only an https address can be added."
      assert Tags.tag_follow_sources(follow) == [Tags.local_tag_follow_source()]
    end

    test "is refused when nothing answers", %{conn: conn, tag: tag, follow: follow} do
      {:ok, live, _html} = live(conn, ~p"/feed")
      open_panel(live, tag)

      html =
        live |> element("#tag-source-form") |> render_submit(%{"source" => "nobody.example"})

      assert html =~ "nobody.example did not answer."
      assert Tags.tag_follow_sources(follow) == [Tags.local_tag_follow_source()]
    end

    test "is refused when it is this installation", %{conn: conn, tag: tag} do
      {:ok, live, _html} = live(conn, ~p"/feed")
      open_panel(live, tag)

      html =
        live
        |> element("#tag-source-form")
        |> render_submit(%{"source" => VutuvWeb.Endpoint.host()})

      assert html =~ "always on anyway"
    end
  end

  describe "the cap" do
    test "says so and takes the field away once the follow is full", %{
      conn: conn,
      tag: tag,
      follow: follow
    } do
      for n <- 1..SourceServers.limit() do
        {:ok, _row} = Tags.add_tag_follow_source(follow, "server#{n}.example")
      end

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = open_panel(live, tag)

      assert html =~ "Switch one off to pick another."
      refute has_element?(live, "#tag-source-form")
      assert live |> element(switch(@good)) |> render() =~ "disabled"
    end
  end

  describe "an installation that reaches nobody" do
    test "offers nothing and says why", %{conn: conn, tag: tag} do
      put_config(:fetch_external_tag_posts, false)

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = open_panel(live, tag)

      assert html =~ "This installation does not read other servers."
      refute html =~ @good
      refute has_element?(live, "#tag-source-form")
      refute_received {:req, _host, _path}
    end

    test "offers nothing when the operator named no servers", %{conn: conn, tag: tag} do
      put_config(:tag_source_servers, [])

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = open_panel(live, tag)

      refute html =~ @good
      # A member may still name one themselves.
      assert has_element?(live, "#tag-source-form")
    end
  end

  describe "German" do
    test "the panel's own words are translated", %{conn: conn, tag: tag, name: name} do
      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> live(~p"/feed")

      html = open_panel(live, tag)

      assert html =~ "Woher soll ##{name} kommen?"
      assert html =~ "vutuv ist immer dabei."
      assert html =~ "Konten"
      assert html =~ "aktiv diesen Monat"
      assert html =~ "Beiträge"
      assert html =~ "hier"
      assert html =~ "vutuv lässt sich nicht abschalten."
      assert html =~ "Weiteren Server hinzufügen"
      assert html =~ "Prüfen und hinzufügen"
    end

    test "a refusal is translated too", %{conn: conn, tag: tag} do
      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> live(~p"/feed")

      open_panel(live, tag)

      html =
        live |> element("#tag-source-form") |> render_submit(%{"source" => "http://#{@good}"})

      assert html =~ "Nur eine https-Adresse"
    end
  end

  describe "the viewer" do
    test "is resolved from the session token, not from a user_id", %{conn: conn, user: user} do
      # The panel writes to somebody's follow, so who the socket thinks it is
      # matters. Revoking the session server-side (a remote logout, #794) must
      # take the socket with it, even though the cookie still names the member.
      user |> Sessions.list_active() |> Enum.each(&Sessions.revoke/1)

      assert {:error, {:redirect, _to}} = live(conn, ~p"/feed")
    end
  end
end
