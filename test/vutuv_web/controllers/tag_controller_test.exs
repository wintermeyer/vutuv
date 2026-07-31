defmodule VutuvWeb.TagControllerTest do
  use VutuvWeb.ConnCase, async: true

  # The public tag pages resolve the `:slug` param to a `Tags.Tag` before every
  # action. An unknown slug must render a clean 404 and *halt* (a missing tag
  # must not fall through into `show/2` with a nil assign). The `:index` action
  # carries no `:slug` param, so the resolver must pass through cleanly there and
  # still render the listing. These guard the swap to the shared resolver plug.

  describe "index (no slug param)" do
    test "renders the tag listing", %{conn: conn} do
      insert(:tag)
      conn = get(conn, ~p"/tags")
      assert conn.status == 200
    end
  end

  describe "show" do
    test "renders an existing tag", %{conn: conn} do
      tag = insert(:tag)
      conn = get(conn, ~p"/tags/#{tag}")
      assert conn.status == 200
    end

    test "returns a clean 404 on an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/tags/does-not-exist")
      assert conn.status == 404
      assert conn.halted
    end
  end

  # A tag page below the indexability bar (fewer than
  # Tags.min_indexable_members/0 visible members and no public post) is a thin
  # near-duplicate in a search index. It stays served and linkable, but carries
  # noindex so crawlers drop it deliberately instead of piling up in Search
  # Console as "crawled - currently not indexed"; the sitemap advertises only
  # tags above the bar.
  describe "search-engine indexability" do
    test "a thin tag page carries the noindex header", %{conn: conn} do
      tag = insert(:tag)
      insert(:user_tag, user: insert(:activated_user), tag: tag)

      conn = get(conn, ~p"/tags/#{tag}")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    test "a tag page above the bar is indexable", %{conn: conn} do
      tag = insert(:tag)

      for _ <- 1..Vutuv.Tags.min_indexable_members() do
        insert(:user_tag, user: insert(:activated_user), tag: tag)
      end

      conn = get(conn, ~p"/tags/#{tag}")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == []
    end

    test "the noindex rides the agent formats too", %{conn: conn} do
      tag = insert(:tag)

      conn = get(conn, ~p"/tags/#{tag}" <> ".md")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end
  end

  # Issue #946: a tag used only in posts (no endorsed members) used to open an
  # empty page. The tag page now lists everything carrying the tag, through the
  # embedded VutuvWeb.TagLive.Timeline - see tag_timeline_live_test.exs for the
  # controls. What matters here is that the dead render (what a crawler and a
  # visitor with no JavaScript get) already carries the posts.
  describe "posts with this tag (issue #946)" do
    test "a tag used only in posts still shows those posts", %{conn: conn} do
      author = insert(:activated_user)

      tag_name = unique_tag_name("Elixir")

      post =
        Vutuv.PostsHelpers.create_post!(author, %{body: "Elixir meetup notes", tags: tag_name})

      html = conn |> get(~p"/tags/#{String.downcase(tag_name)}") |> html_response(200)

      assert html =~ "tag-timeline"
      assert html =~ "Elixir meetup notes"
      assert html =~ "/#{author.username}/posts/#{post.id}"
      # The posts render as flat rows in one card (the feed/archive treatment),
      # not separate full-width cards - keeps the desktop layout tidy.
      assert html =~ "data-post-list"
    end

    test "the front matter rides above the timeline whatever ?page says", %{conn: conn} do
      # The timeline pages over the socket now, so the description and the
      # member list no longer disappear on a `?page=2` that no longer drives
      # them.
      insert(:tag, name: "Busy", slug: "busy", description: "A very busy tag indeed.")

      html = conn |> get(~p"/tags/busy?page=2") |> html_response(200)

      assert html =~ "A very busy tag indeed."
    end

    test "an empty tag says so instead of showing a bare list", %{conn: conn} do
      insert(:tag, name: "Empty", slug: "empty")

      html = conn |> get(~p"/tags/empty") |> html_response(200)

      assert html =~ ~s(id="tag-timeline-empty")
      refute html =~ "data-post-list"
    end
  end

  # Issue #877: the "Add this tag" button was removed from the public tag page.
  # "Add this tag" was ambiguous ("create/define this tag" vs "add it to my
  # profile" — it misled the #844 reporter into a 404), redundant with the
  # /settings/tags editor, and out of step with vutuv's showcase pages, which
  # carry no profile-mutating controls. Adding a tag now lives only in
  # /settings/tags (+ the profile Tags card), so the tag page is pure discovery.
  describe "the tag page carries no profile-mutation control (issue #877)" do
    test "a logged-in visitor without the tag sees no \"Add this tag\" button", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      tag = insert(:tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      refute html =~ "Add this tag"
      refute html =~ ~s(data-to="/settings/tags?tag_param)
    end
  end
end
