defmodule VutuvWeb.ExternalTagCopiesTest do
  @moduledoc """
  One post found on several servers is one card (issue #2163).

  A find is stored once per (tag, server, remote id), so the same status read
  off three servers is three rows with nothing in that key to relate them — and
  the feed and the tag page drew all three, identical but for their "found
  through" line, while the figure above the list counted rows. Measured on a
  copy of production: 78 rows for 49 originals, and one tag page showing 20
  cards for 9 posts.

  What is asserted here is the fold and what it may not do: several copies read
  as one card, the card is the copy the author's **own** server served when we
  hold one, the figure counts posts, the disclosure names every server that
  carried it, and two genuinely different posts stay two cards. Plus the German,
  by name, because `gettext.extract --merge` has fuzzy-filled a new string with a
  neighbour's translation three times on this milestone.

  `async: false`: the module holds `:fetch_external_tag_posts` down, which
  `Vutuv.Tags.ExternalPosts.enabled?/0` and the supervision tree both read.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.ExternalTagHelpers

  alias Vutuv.Repo
  alias Vutuv.Tags.ExternalPost

  @author_host Vutuv.ExternalTagHelpers.author_host()

  # Three servers this installation asked, none of them the author's home, so a
  # card that picked one of them by accident cannot pass by looking right.
  @relay_a Vutuv.ExternalTagHelpers.tag_source()
  @relay_b "social.example"
  @relay_c "hachyderm.example"

  setup do
    put_config(:fetch_external_tag_posts, true)
    :ok
  end

  defp followed_tag(user, sources) do
    tag = insert(:tag)

    Enum.each(List.wrap(sources), &follow_tag_through(user, tag, &1))

    tag
  end

  # The same status, as each of `sources` handed it over: one row per server,
  # one address, one author. Returned oldest first, which is the order they
  # were stored in.
  defp copies_of(tag, sources) do
    Enum.map(sources, fn source ->
      external_post(tag,
        source: source,
        author_host: @author_host,
        url: "https://#{@author_host}/@ada/4711",
        text: "EIN FUND AUF MEHREREN SERVERN"
      )
    end)
  end

  # Every card on the page, by the id of the row it is drawn from.
  defp cards(html) do
    ~r/data-external-post="([0-9a-f-]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_whole, id] -> id end)
  end

  describe "the feed" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "three copies of one original are one card", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @relay_b, @relay_c])
      copies_of(tag, [@relay_a, @relay_b, @relay_c])

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert length(cards(html)) == 1
    end

    test "the card is the copy the author's own server served", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @author_host])
      [relayed, home] = copies_of(tag, [@relay_a, @author_host])

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert cards(html) == [home.id]
      refute html =~ relayed.id
    end

    test "with no copy from the author's own server the card is the one we stored first", %{
      conn: conn,
      user: user
    } do
      tag = followed_tag(user, [@relay_a, @relay_b])
      [first, _second] = copies_of(tag, [@relay_a, @relay_b])

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert cards(html) == [first.id]
    end

    test "a genuinely different post is not folded into it", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @relay_b])
      copies_of(tag, [@relay_a, @relay_b])

      other =
        external_post(tag,
          source: @relay_a,
          author_host: @author_host,
          url: "https://#{@author_host}/@ada/4712",
          text: "EIN ZWEITER FUND"
        )

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert length(cards(html)) == 2
      assert html =~ other.id
      assert html =~ "EIN ZWEITER FUND"
    end
  end

  describe "the tag page" do
    setup do
      user = insert(:activated_user)
      {:ok, user: user}
    end

    test "the figure above the list counts posts and not rows", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @relay_b, @relay_c])
      copies_of(tag, [@relay_a, @relay_b, @relay_c])

      external_post(tag,
        source: @relay_a,
        author_host: @author_host,
        url: "https://#{@author_host}/@ada/4712",
        text: "EIN ZWEITER FUND"
      )

      html = conn |> get(~p"/tags/#{tag.slug}?source=fediverse") |> html_response(200)

      assert length(cards(html)) == 2
      assert html =~ ~r/data-timeline-total[^>]*>\s*2 posts/
    end

    test "the disclosure names every server that carried it", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @relay_b, @relay_c])
      copies_of(tag, [@relay_a, @relay_b, @relay_c])

      html = conn |> get(~p"/tags/#{tag.slug}?source=fediverse") |> html_response(200)

      assert html =~ ~s(data-external-servers="3")
      assert html =~ ~s(data-external-source="#{@relay_a}")
      assert html =~ ~s(data-external-source="#{@relay_b}")
      assert html =~ ~s(data-external-source="#{@relay_c}")
    end

    test "one server keeps the quiet line it always had", %{conn: conn, user: user} do
      tag = followed_tag(user, @relay_a)
      copies_of(tag, [@relay_a])

      html = conn |> get(~p"/tags/#{tag.slug}?source=fediverse") |> html_response(200)

      assert html =~ ~s(data-external-source="#{@relay_a}")
      refute html =~ "data-external-servers"
    end

    test "the German reads the servers out by name", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @relay_b])
      copies_of(tag, [@relay_a, @relay_b])

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/tags/#{tag.slug}?source=fediverse")
        |> html_response(200)

      assert html =~ "Gefunden über diese Server"
      assert html =~ ~r/data-timeline-total[^>]*>\s*1 Beitrag/
    end

    # One entry, not one per server — and the list leads with the server the
    # entry is drawn from, which is the one `found_via` names.
    test "the agent formats name every server too", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @relay_b])
      copies_of(tag, [@relay_a, @relay_b])

      json = conn |> get("/tags/#{tag.slug}.json") |> json_response(200)

      assert [entry] = json["posts"]
      assert entry["found_via"] == @relay_a
      assert entry["servers"] == [@relay_a, @relay_b]
    end
  end

  describe "a report from a folded card" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    # The dialog over a relayed card promises one copy and says the others
    # stay, and that is what has to happen: the card does not vanish, it loses
    # the server that filed the reported row.
    test "a relayed card takes its own server's copy and keeps the rest", %{
      conn: conn,
      user: user
    } do
      tag = followed_tag(user, [@relay_a, @relay_b])
      [first, second] = copies_of(tag, [@relay_a, @relay_b])

      {:ok, view, before} = live(conn, ~p"/feed")

      assert cards(before) == [first.id]
      assert before =~ ~s(data-external-servers="2")

      html =
        view
        |> element(~s([data-external-post="#{first.id}"] [phx-click="report-external-post"]))
        |> render_click()

      assert Repo.get!(ExternalPost, first.id).reported_at
      refute Repo.get!(ExternalPost, second.id).reported_at

      assert html =~ "EIN FUND AUF MEHREREN SERVERN"
      assert cards(html) == [second.id]
      refute html =~ "data-external-servers"
    end

    # And the other half: the author's own server's card speaks for every copy,
    # so the post really does leave the page.
    test "the author's own card takes every copy and the card goes", %{conn: conn, user: user} do
      tag = followed_tag(user, [@relay_a, @author_host])
      [relayed, home] = copies_of(tag, [@relay_a, @author_host])

      {:ok, view, before} = live(conn, ~p"/feed")

      assert cards(before) == [home.id]
      assert before =~ ~s(data-external-servers="2")

      html =
        view
        |> element(~s([data-external-post="#{home.id}"] [phx-click="report-external-post"]))
        |> render_click()

      assert Repo.get!(ExternalPost, relayed.id).reported_at
      refute html =~ "EIN FUND AUF MEHREREN SERVERN"
    end
  end
end
