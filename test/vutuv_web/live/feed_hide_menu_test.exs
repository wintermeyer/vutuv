defmodule VutuvWeb.PostLive.FeedHideMenuTest do
  @moduledoc """
  The ⋯ menu's hide list: one checkbox per tag the post carries, plus the
  reach beside it.

  A post brings several tags along and the reach is a separate question for
  each one — hiding `#news` only where this account says it, but `#Berlin`
  everywhere. That is two axes, so the row carries both: the tick says whether
  the rule exists, the select says for whom, and changing the select rewrites
  the rule rather than adding a second one.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts

  defp with_tagged_post(conn) do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user, first_name: "Lena", last_name: "Loud")
    insert(:follow, follower: user, followee: friend)

    {:ok, post} =
      Posts.create_post(friend, %{body: "Bahnhof und Fahrplan", tags: "news, bremen"})

    %{conn: conn, user: user, friend: friend, post: post}
  end

  defp row(post, pattern), do: ~s(form[data-hide-rule="tag:#{pattern}"][data-post="#{post.id}"])

  # A post from another network, closing on its hashtags the way they arrive.
  defp remote_post(user) do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them",
        host: "social.example",
        handle: "them",
        name: "Them Themself",
        inbox_uri: "https://social.example/users/them/inbox"
      })

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/1"
    })

    now = DateTime.utc_now(:second)

    post =
      Repo.insert!(%RemotePost{
        remote_account_id: account.id,
        object_uri: "https://social.example/posts/1",
        origin_url: "https://social.example/@them/1",
        content_text: "Tomahawks für die Bundeswehr\n\n#news #ruestung",
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400)
      })

    {account, post}
  end

  test "the menu lists the post's tags with a tick each", %{conn: conn} do
    %{conn: conn, post: post} = with_tagged_post(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")

    assert has_element?(live, row(post, "news"))
    assert has_element?(live, row(post, "bremen"))
    # Nothing is ticked before the member ticks something.
    refute has_element?(live, row(post, "news") <> " input[type=checkbox][checked]")
  end

  test "a tick writes the rule with the reach the select names", %{conn: conn} do
    %{conn: conn, user: user, friend: friend, post: post} = with_tagged_post(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")

    live
    |> element(row(post, "news"))
    |> render_change(%{"on" => "1", "scope" => "@" <> friend.username})

    assert [%{kind: :tag, pattern: "news", account: account}] = ContentFilters.list_for_user(user)
    assert account == "@" <> friend.username
  end

  test "changing the reach rewrites the rule instead of adding a second", %{conn: conn} do
    %{conn: conn, user: user, friend: friend, post: post} = with_tagged_post(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")

    live
    |> element(row(post, "news"))
    |> render_change(%{"on" => "1", "scope" => "@" <> friend.username})

    live
    |> element(row(post, "news"))
    |> render_change(%{"on" => "1", "scope" => ""})

    assert [%{kind: :tag, pattern: "news", account: "*"}] = ContentFilters.list_for_user(user)
  end

  test "unticking takes the rule back", %{conn: conn} do
    %{conn: conn, user: user, post: post} = with_tagged_post(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")

    live |> element(row(post, "news")) |> render_change(%{"on" => "1", "scope" => ""})
    assert [_] = ContentFilters.list_for_user(user)

    # An unticked checkbox sends no value at all — that absence IS the event,
    # and `render_change/2` on the element cannot express it: it merges into the
    # form's current DOM state, where the box is now ticked. So this one goes
    # through the event directly, exactly as the browser would send it.
    render_change(live, "hide-rule", %{
      "kind" => "tag",
      "pattern" => "news",
      "post_id" => post.id,
      "scope" => ""
    })

    assert [] = ContentFilters.list_for_user(user)
  end

  test "the free word field hides a phrase from this post", %{conn: conn} do
    %{conn: conn, user: user, post: post} = with_tagged_post(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")

    live
    |> element(~s(form[data-hide-word][data-post="#{post.id}"]))
    |> render_submit(%{"pattern" => "Fahrplan", "scope" => ""})

    assert [%{kind: :keyword, pattern: "Fahrplan"}] = ContentFilters.list_for_user(user)
  end

  test "the row reads back what it just wrote", %{conn: conn} do
    %{conn: conn, friend: friend, post: post} = with_tagged_post(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")

    live
    |> element(row(post, "news"))
    |> render_change(%{"on" => "1", "scope" => "@" <> friend.username})

    # The post the reader is standing on stays open, so the row is still there
    # to say what now holds — ticked, and with the reach they picked.
    assert has_element?(live, row(post, "news") <> " input[type=checkbox][checked]")

    assert has_element?(
             live,
             row(post, "news") <> ~s( option[value="@#{friend.username}"][selected])
           )
  end

  describe "a post from another network" do
    test "offers its hashtags, and a whole server as one of the reaches", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_account, post} = remote_post(user)

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(live, row(post, "news"))
      # The reach a member's own post cannot have: a news house federates one
      # story from a dozen of its accounts.
      assert has_element?(
               live,
               row(post, "news") <> ~s( option[value="*@social.example"])
             )
    end

    test "hiding a tag there folds the card", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_account, post} = remote_post(user)

      {:ok, live, html} = live(conn, ~p"/feed")
      assert html =~ "Tomahawks"

      live
      |> element(row(post, "news"))
      |> render_change(%{"on" => "1", "scope" => "*@social.example"})

      assert [%{kind: :tag, pattern: "news", account: "*@social.example"}] =
               ContentFilters.list_for_user(user)
    end
  end

  test "a rule aimed at another account leaves this row alone", %{conn: conn} do
    %{conn: conn, user: user, post: post} = with_tagged_post(conn)
    stranger = insert(:activated_user, first_name: "Someone", last_name: "Else")

    {:ok, _} =
      ContentFilters.create_filter(user, %{
        kind: :tag,
        pattern: "news",
        account: "@" <> stranger.username
      })

    {:ok, live, _html} = live(conn, ~p"/feed")

    # It says nothing about this post, so it must not tick this box — a tick
    # here would rewrite a rule the reader made somewhere else.
    refute has_element?(live, row(post, "news") <> " input[type=checkbox][checked]")
  end
end
