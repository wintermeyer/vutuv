defmodule VutuvWeb.FeedSourceTabsTest do
  @moduledoc """
  The /feed source tabs: All / vutuv / Fediverse.

  The two named tabs partition the timeline by what kind of post an entry
  carries, so the tests here are mostly about that split holding at its edges —
  the one source that produces both kinds (a boost, issue #1167), the live
  arrivals that never went through a query, and an installation with no
  fediverse at all.

  Not async: one test flips `:fediverse_enabled`, which is application env —
  process/node state the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Social

  defp remote_account(user, handle) do
    actor = "https://social.example/users/#{handle}"

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: actor,
        host: "social.example",
        handle: handle,
        name: String.capitalize(handle),
        inbox_uri: actor <> "/inbox"
      })

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{handle}"
    })

    account
  end

  defp cached_post(account, body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/posts/#{unique}",
      origin_url: "https://social.example/@them/#{unique}",
      content_text: body,
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  # A member here the viewer follows, plus a post of theirs.
  defp followed_post(viewer, body) do
    author = insert(:user, email_confirmed?: true)
    Social.follow(viewer, author.id)
    {:ok, post} = Posts.create_post(author, %{body: body})
    {author, post}
  end

  # What the **timeline** shows, which is the only part a tab governs. The
  # desktop "Suggested posts" rail draws from members the viewer does not
  # follow and renders on every tab, so a page-wide match finds a filtered-out
  # post there and reads as the filter having failed.
  defp timeline(view) do
    if has_element?(view, "#feed-posts"), do: render(element(view, "#feed-posts")), else: ""
  end

  describe "the tab bar" do
    test "renders the three source tabs above the timeline", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "a vutuv post")

      {:ok, view, html} = live(conn, ~p"/feed")

      assert has_element?(view, "#feed-source-tabs [data-post-filter-tab='all']")
      assert has_element?(view, "#feed-source-tabs [data-post-filter-tab='vutuv']")
      assert has_element?(view, "#feed-source-tabs [data-post-filter-tab='fediverse']")
      assert html =~ "Fediverse"

      # "All" is where a mount opens; the tab reads as selected.
      assert has_element?(view, "[data-post-filter-tab='all'][aria-pressed='true']")
    end

    test "a completely empty feed shows the invitation instead of tabs", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "#feed-source-tabs")
    end

    test "an installation with no fediverse gets no tabs", %{conn: conn} do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.put_env(:vutuv, :fediverse_enabled, true) end)

      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "a vutuv post")

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "#feed-source-tabs")
    end
  end

  describe "switching tabs" do
    test "vutuv shows only vutuv posts, fediverse only the cached ones", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "written here on vutuv")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")

      # All: both halves.
      assert timeline(view) =~ "written here on vutuv"
      assert timeline(view) =~ "written out there"

      render_click(view, "filter-source", %{"type" => "vutuv"})
      assert timeline(view) =~ "written here on vutuv"
      refute timeline(view) =~ "written out there"
      assert has_element?(view, "[data-post-filter-tab='vutuv'][aria-pressed='true']")

      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert timeline(view) =~ "written out there"
      refute timeline(view) =~ "written here on vutuv"

      # And back again, so a tab is never a one-way door.
      render_click(view, "filter-source", %{"type" => "all"})
      assert timeline(view) =~ "written here on vutuv"
      assert timeline(view) =~ "written out there"
    end

    test "an unknown tab value falls back to the whole feed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "still here")

      {:ok, view, _html} = live(conn, ~p"/feed")

      render_click(view, "filter-source", %{"type" => "nonsense"})

      assert timeline(view) =~ "still here"
      assert has_element?(view, "[data-post-filter-tab='all'][aria-pressed='true']")
    end

    test "the German render names the tabs and the empty fediverse tab in German", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "the only post")
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, view, html} = live(conn, ~p"/feed")

      # The two proper names stay as they are; only "All" is a word.
      assert html =~ "Alle"
      assert html =~ "Fediverse"

      assert render_click(view, "filter-source", %{"type" => "fediverse"}) =~
               "Noch nichts aus dem Fediverse"
    end

    test "an empty vutuv tab says so in German too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = remote_account(user, "them")
      cached_post(account, "written out there")
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert render_click(view, "filter-source", %{"type" => "vutuv"}) =~
               "Noch nichts von vutuv"
    end

    test "an empty tab says which half is missing and keeps the tabs", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_author, _post} = followed_post(user, "the only post")

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = render_click(view, "filter-source", %{"type" => "fediverse"})

      assert html =~ "Nothing from the fediverse yet"
      # Without the tabs an empty tab would be a dead end.
      assert has_element?(view, "#feed-source-tabs")
    end
  end

  describe "boosts, the one source that produces both kinds" do
    test "a boosted vutuv post is a vutuv post, a boosted remote post is not", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      booster = remote_account(user, "booster")

      # A member's own post, passed on by an account out there (issue #1167).
      author = insert(:user, email_confirmed?: true)
      {:ok, local} = Posts.create_post(author, %{body: "a member post, boosted"})

      # And a cached post from a third server, passed on by the same account.
      other = remote_account(user, "third")
      remote = cached_post(other, "a remote post, boosted")

      now = DateTime.utc_now(:second)

      Repo.insert!(%PostBoost{
        remote_account_id: booster.id,
        post_id: local.id,
        activity_id: "https://social.example/activities/1",
        announced_at: now
      })

      Repo.insert!(%PostBoost{
        remote_account_id: booster.id,
        remote_post_id: remote.id,
        activity_id: "https://social.example/activities/2",
        announced_at: now
      })

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert timeline(view) =~ "a member post, boosted"
      assert timeline(view) =~ "a remote post, boosted"

      render_click(view, "filter-source", %{"type" => "vutuv"})
      assert timeline(view) =~ "a member post, boosted"
      refute timeline(view) =~ "a remote post, boosted"

      render_click(view, "filter-source", %{"type" => "fediverse"})
      assert timeline(view) =~ "a remote post, boosted"
      refute timeline(view) =~ "a member post, boosted"
    end
  end

  describe "live arrivals respect the active tab" do
    test "a followed member's new post does not fill the pill on the Fediverse tab", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})

      refute has_element?(view, "#show-new-posts")
      refute timeline(view) =~ "arriving live"
    end

    test "the same post does fill the pill on the vutuv tab", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {author, _post} = followed_post(user, "an older post")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "vutuv"})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving live"})

      assert has_element?(view, "#show-new-posts")
      render_click(view, "show-new")
      assert timeline(view) =~ "arriving live"
    end

    test "the viewer's own post pulls the feed back to All rather than vanishing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _own} = Posts.create_post(user, %{body: "my own words"})

      assert timeline(view) =~ "my own words"
      assert has_element?(view, "[data-post-filter-tab='all'][aria-pressed='true']")
    end
  end
end
