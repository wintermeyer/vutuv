defmodule VutuvWeb.TagLive.SourcesTest do
  @moduledoc """
  The source chip and its panel on the tag page (issue #2157).

  The feed's tag card is hidden on a phone, so the tag page is where a phone
  reader changes a followed tag's servers. The panel is the feed's own
  (`VutuvWeb.PostLive.TagSources`); this covers the second host.

  `async: false` for the same reason as `VutuvWeb.PostLive.FeedTagSourcesTest`:
  the servers, the fetch flag and the probe stub are application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.ExternalTagHelpers

  alias Vutuv.Sessions
  alias Vutuv.Tags
  alias VutuvWeb.TagLive.Sources

  @good "troet.example"

  setup %{conn: conn} do
    put_config(:fetch_external_tag_posts, true)
    put_config(:tag_source_servers, [@good])
    stub_servers(%{@good => %{accounts: 49_157, language: "de"}})

    {conn, user} = create_and_login_user(conn)

    name = Vutuv.Factory.unique_tag_name("Koblenz")
    tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))

    %{conn: conn, user: user, tag: tag, name: name}
  end

  # The chip lives in a dead controller page, so the socket is driven on its own
  # with the session the template hands it, plus the cookie's token.
  defp sources(user, tag) do
    session = shell_session(user, Sources.session(tag, 1))
    {:ok, view, _html} = live_isolated(build_conn(), Sources, session: session)
    view
  end

  describe "the page" do
    test "puts the chip beside the follow button of a member who follows the tag", %{
      conn: conn,
      user: user,
      tag: tag
    } do
      {:ok, _follow} = Tags.follow_tag(user, tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      assert html =~ ~s(id="tag-sources-chip-#{tag.id}")

      # Issue #2166: on the page a phone reads, the chip is a full finger's
      # target that still stands on the follow pill's line.
      chip = html |> LazyHTML.from_document() |> LazyHTML.query(source_chip(tag))
      assert LazyHTML.attribute(chip, "title") == ["Choose which servers this tag comes from"]
      assert chip |> LazyHTML.attribute("class") |> hd() =~ "h-10"
      assert chip |> LazyHTML.query("svg") |> Enum.count() == 1
    end

    test "has no chip for a member who does not follow the tag", %{conn: conn, tag: tag} do
      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      refute html =~ "tag-sources"
    end

    test "has no chip for an anonymous reader", %{user: user, tag: tag} do
      {:ok, _follow} = Tags.follow_tag(user, tag)

      html = build_conn() |> get(~p"/tags/#{tag}") |> html_response(200)

      refute html =~ "tag-sources"
    end

    test "has no chip when the installation reads no other server", %{
      conn: conn,
      user: user,
      tag: tag
    } do
      put_config(:fetch_external_tag_posts, false)
      {:ok, _follow} = Tags.follow_tag(user, tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      refute html =~ "tag-sources"
    end
  end

  describe "the socket" do
    test "opens the panel, switches a server on and adds one by hand", %{user: user, tag: tag} do
      {:ok, follow} = Tags.follow_tag(user, tag)
      stub_servers(%{@good => %{language: "de"}, "kowelenz.example" => %{language: "de"}})
      view = sources(user, tag)

      refute has_element?(view, "#tag-sources-panel")
      view |> element(source_chip(tag)) |> render_click()
      render_async(view)

      assert has_element?(view, "#tag-sources-panel")
      assert has_element?(view, ~s(#{source_chip(tag)}[aria-expanded="true"]))

      view |> element(source_switch(@good)) |> render_click()
      assert @good in Tags.tag_follow_sources(follow)
      assert view |> element(source_chip(tag)) |> render() =~ ">2<"

      view |> element("#tag-source-form") |> render_submit(%{"source" => "kowelenz.example"})
      assert "kowelenz.example" in Tags.tag_follow_sources(follow)
      assert view |> element(source_chip(tag)) |> render() =~ ">3<"
      assert has_element?(view, "#tag-source-own-rows #{source_row("kowelenz.example")}")
      assert view |> element("#tag-sources-added") |> render() =~ "kowelenz.example now feeds"

      # A refusal quotes the address as the member wrote it, and keeps it in
      # the field for them to correct.
      view |> element("#tag-source-form") |> render_submit(%{"source" => "Kein Server"})
      assert render(view) =~ "Kein Server is not a server name."
      assert has_element?(view, ~s(#tag-source-form input[value="Kein Server"]))

      view |> element("#tag-sources-close") |> render_click()
      refute has_element?(view, "#tag-sources-panel")
      assert has_element?(view, ~s(#{source_chip(tag)}[aria-expanded="false"]))
    end

    test "shows nothing to a member who does not follow the tag", %{user: user, tag: tag} do
      view = sources(user, tag)

      refute has_element?(view, source_chip(tag))
    end

    test "is resolved from the session token, so a revoked device writes nothing", %{
      conn: conn,
      user: user,
      tag: tag
    } do
      {:ok, follow} = Tags.follow_tag(user, tag)
      {token, session} = Sessions.start_session(user, conn, alert: false)
      Sessions.revoke(session)

      # The curated map still names the tag and a count, as the controller
      # rendered it; only the token decides who is writing.
      session =
        Map.merge(Sources.session(tag, 1), %{"session_token" => token, "user_id" => user.id})

      {:ok, view, _html} = live_isolated(build_conn(), Sources, session: session)

      refute has_element?(view, source_chip(tag))
      refute has_element?(view, "#tag-sources")

      render_click(view, "tag-sources", %{"id" => tag.id})
      render_click(view, "tag-source-add", %{"source" => @good})

      assert Tags.tag_follow_sources(follow) == [Tags.local_tag_follow_source()]
    end
  end

  describe "German" do
    test "the chip's label and the panel's title", %{conn: conn, user: user, tag: tag, name: name} do
      {:ok, _follow} = Tags.follow_tag(user, tag)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/tags/#{tag}")
        |> html_response(200)

      assert html =~ "#{name} kommt von 1 Server. Das lässt sich ändern."

      user |> Ecto.Changeset.change(locale: "de") |> Repo.update!()
      view = sources(user, tag)
      view |> element(source_chip(tag)) |> render_click()

      assert render_async(view) =~ "Woher soll ##{name} kommen?"
    end
  end
end
