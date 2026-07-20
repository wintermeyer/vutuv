defmodule VutuvWeb.TagControllerTest do
  use VutuvWeb.ConnCase, async: true

  # The public tag pages resolve the `:slug` param to a `Tags.Tag` before every
  # action. An unknown slug must render a clean 404 and *halt* (a missing tag
  # must not fall through into `show/2` with a nil assign). The `:index` action
  # carries no `:slug` param, so the resolver must pass through cleanly there and
  # still render the listing. These guard the swap to the shared resolver plug.

  describe "index (no slug param)" do
    test "renders the tag listing", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")
      conn = get(conn, ~p"/tags")
      assert conn.status == 200
    end
  end

  describe "show" do
    test "renders an existing tag", %{conn: conn} do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      conn = get(conn, ~p"/tags/#{tag}")
      assert conn.status == 200
    end

    test "returns a clean 404 on an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/tags/does-not-exist")
      assert conn.status == 404
      assert conn.halted
    end
  end

  # Issue #946: a tag used only in posts (no endorsed members) used to open an
  # empty page. The tag page now lists the public posts carrying the tag.
  describe "posts with this tag (issue #946)" do
    test "a tag used only in posts still shows those posts", %{conn: conn} do
      author = insert(:activated_user)

      post =
        Vutuv.PostsHelpers.create_post!(author, %{body: "Elixir meetup notes", tags: "elixir"})

      html = conn |> get(~p"/tags/elixir") |> html_response(200)

      assert html =~ "tag-posts"
      assert html =~ "Elixir meetup notes"
      assert html =~ "/#{author.username}/posts/#{post.id}"
      # The posts render as flat rows in one card (the feed/archive treatment),
      # not separate full-width cards - keeps the desktop layout tidy.
      assert html =~ "data-post-list"
    end

    test "posts are paginated; page 2 drops the overview and shows older posts", %{conn: conn} do
      author = insert(:activated_user)
      per_page = Vutuv.Posts.tag_posts_per_page()

      tag =
        insert(:tag, name: "Busy", slug: "busy", description: "A very busy tag indeed.")

      # A recommended member so the overview card has visible content to gate on.
      insert(:user_tag, tag: tag, user: insert(:activated_user))

      posts =
        for i <- 1..(per_page + 1) do
          Vutuv.PostsHelpers.create_post!(author, %{body: "Busy post number #{i}", tags: "busy"})
        end

      # UUID v7 ids sort by creation, so the last-created is newest.
      oldest = List.first(posts)
      newest = List.last(posts)
      oldest_link = "/#{author.username}/posts/#{oldest.id}"
      newest_link = "/#{author.username}/posts/#{newest.id}"

      # Page 1: the overview (description) shows, the newest post shows, the
      # oldest is pushed to page 2, and there is a link to page 2.
      page1 = conn |> get(~p"/tags/busy") |> html_response(200)
      assert page1 =~ "A very busy tag indeed."
      assert page1 =~ "page=2"
      assert page1 =~ newest_link
      refute page1 =~ oldest_link

      # Page 2: the overview is gone and only the remaining (oldest) post shows.
      page2 = conn |> get(~p"/tags/busy?page=2") |> html_response(200)
      refute page2 =~ "A very busy tag indeed."
      assert page2 =~ oldest_link
      refute page2 =~ newest_link
    end

    test "the posts section is absent when no public post carries the tag", %{conn: conn} do
      insert(:tag, name: "Empty", slug: "empty")

      html = conn |> get(~p"/tags/empty") |> html_response(200)

      refute html =~ ~s(id="tag-posts")
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
      insert(:tag, name: "Elixir", slug: "elixir")

      html = conn |> get(~p"/tags/elixir") |> html_response(200)

      refute html =~ "Add this tag"
      refute html =~ ~s(data-to="/settings/tags?tag_param)
    end
  end
end
