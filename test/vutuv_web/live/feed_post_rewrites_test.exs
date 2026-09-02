defmodule VutuvWeb.FeedPostRewritesTest do
  @moduledoc """
  A reader's per-author search-and-replace rules in the home feed
  (`Vutuv.PostRewrites`): the card shows the rewritten text for that reader
  alone, and every card's ⋯ menu leads to the editor for its author.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.Follow
  alias Vutuv.PostRewrites

  @account "@golemde@flipboard.com"
  @footer "Gepostet in GOLEM @golem-Golemde"

  defp golem_account,
    do:
      remote_account(
        actor_uri: "https://flipboard.com/@Golemde",
        handle: "Golemde",
        name: "Golem.de"
      )

  defp follow_remote(user, account) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp remote_post(account),
    do: cached_post(account, content_text: "Dyson stellt Zahnbürste vor\n\n" <> @footer)

  test "rewrites a followed account's post for the reader who wrote the rule alone", %{conn: conn} do
    {conn, reader} = create_and_login_user(conn)

    {conn_other, other} =
      create_and_login_user(
        Plug.Test.init_test_session(build_conn(), %{}),
        registration_attrs("other")
      )

    account = golem_account()
    follow_remote(reader, account)
    follow_remote(other, account)
    post = remote_post(account)

    {:ok, _rule} = PostRewrites.create_rule(reader, @account, %{pattern: "^Gepostet in .*$"})

    {:ok, live, _html} = live(conn, ~p"/feed")
    card = live |> element(~s([data-remote-post="#{post.id}"])) |> render()
    assert card =~ "Dyson stellt Zahnbürste vor"
    refute card =~ "Gepostet in"

    # The other follower reads the post as it was written.
    {:ok, live, _html} = live(conn_other, ~p"/feed")
    assert live |> element(~s([data-remote-post="#{post.id}"])) |> render() =~ @footer
  end

  test "the remote card's ⋯ menu leads to the editor with this post as the sample", %{conn: conn} do
    {conn, reader} = create_and_login_user(conn)
    account = golem_account()
    follow_remote(reader, account)
    post = remote_post(account)

    {:ok, live, _html} = live(conn, ~p"/feed")

    assert has_element?(
             live,
             ~s(#remote-post-menu-#{post.id} a[href="/settings/rewrites/%40golemde%40flipboard.com?remote_post=#{post.id}"])
           )
  end

  test "rewrites a member's post by their handle, never the reader's own, and links from the card",
       %{conn: conn} do
    {conn, reader} = create_and_login_user(conn)
    author = insert(:activated_user, username: "erika-rewrites")
    insert(:follow, follower: reader, followee: author)
    theirs = insert(:post, user: author, body: "Hallo zusammen -- Gruß Erika")
    mine = insert(:post, user: reader, body: "Meins -- Gruß Erika")

    {:ok, _} = PostRewrites.create_rule(reader, "@erika-rewrites", %{pattern: " -- Gruß Erika"})

    {:ok, _} =
      PostRewrites.create_rule(reader, "@" <> reader.username, %{pattern: " -- Gruß Erika"})

    {:ok, live, _html} = live(conn, ~p"/feed")

    their_body = live |> element(~s([id^="post-body-"][id*="#{theirs.id}"])) |> render()
    assert their_body =~ "Hallo zusammen"
    refute their_body =~ "Gruß Erika"

    # Still there (the renderer turns the `--` into a dash, the rule never ran).
    assert live |> element(~s([id^="post-body-"][id*="#{mine.id}"])) |> render() =~ "Gruß Erika"

    assert has_element?(
             live,
             ~s(a[href="/settings/rewrites/%40erika-rewrites?post=#{theirs.id}"])
           )
  end
end
