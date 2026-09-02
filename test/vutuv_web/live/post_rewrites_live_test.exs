defmodule VutuvWeb.PostRewritesLiveTest do
  @moduledoc """
  The per-author search-and-replace editor (`/settings/rewrites/:account`): the
  prefilled first rule, the live before/after, the ordered list, and the way
  back to the page the member came from.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.Follow
  alias Vutuv.PostRewrites

  @account "@golemde@flipboard.com"
  @footer "Gepostet in GOLEM @golem-Golemde"
  @text "Tablet Amazon Fire Max 11 mit Alexa stark reduziert\nhttps://www.golem.de/news/x.html \n\n" <>
          @footer

  defp followed_remote_post(user) do
    account =
      remote_account(
        actor_uri: "https://flipboard.com/@Golemde",
        handle: "Golemde",
        name: "Golem.de"
      )

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/golem"
    })

    cached_post(account, content_text: @text)
  end

  defp editor_path(post), do: ~p"/settings/rewrites/#{@account}?remote_post=#{post.id}"

  test "redirects anonymous visitors", %{conn: conn} do
    conn = get(conn, ~p"/settings/rewrites")
    assert redirected_to(conn) == ~p"/"
  end

  describe "the editor" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, post: followed_remote_post(user)}
    end

    test "prefills the sample's last line as a first rule and previews it live", %{
      conn: conn,
      post: post
    } do
      {:ok, live, html} = live(conn, editor_path(post))

      assert html =~ ~s(value="^Gepostet in GOLEM @golem-Golemde$")
      assert html =~ "matches 1 time in this post by @golemde@flipboard.com"

      # The before pane marks the catch; the after pane no longer carries it.
      assert live |> element("#rewrite-before mark") |> render() =~ @footer
      refute live |> element("#rewrite-after") |> render() =~ "Gepostet"
      assert live |> element("#rewrite-after") |> render() =~ "Tablet Amazon Fire Max 11"

      # Typing a rule that catches nothing says so, and the after pane is whole.
      html =
        live
        |> form("#rewrite-form", rule: %{pattern: "nothing like this", replacement: ""})
        |> render_change()

      assert html =~ "matches 0 times"
      assert live |> element("#rewrite-after") |> render() =~ "Gepostet"
    end

    test "adds, reorders and removes rules over the socket", %{conn: conn, post: post, user: user} do
      {:ok, live, _html} = live(conn, editor_path(post))

      live
      |> form("#rewrite-form", rule: %{pattern: "^Gepostet in .*$", replacement: ""})
      |> render_submit()

      live
      |> form("#rewrite-form", rule: %{pattern: "Tablet", replacement: "Tablett"})
      |> render_submit()

      assert [first, second] = PostRewrites.list_for_account(user, @account)
      assert first.pattern == "^Gepostet in .*$"
      assert second.pattern == "Tablet"

      # With nothing being typed, the panes show what the saved rules do.
      html = render(live)
      assert html =~ "Your saved rules change this post"
      after_pane = live |> element("#rewrite-after") |> render()
      assert after_pane =~ "Tablett Amazon"
      refute after_pane =~ "Gepostet"

      live |> element("#move-up-#{second.id}") |> render_click()
      assert [%{id: moved_up}, _] = PostRewrites.list_for_account(user, @account)
      assert moved_up == second.id

      html = render(live)

      assert [pos_second, pos_first] =
               for(r <- [second, first], do: :binary.match(html, "rewrite-#{r.id}") |> elem(0))

      assert pos_second < pos_first

      live |> element("#delete-#{first.id}") |> render_click()
      assert [%{id: only}] = PostRewrites.list_for_account(user, @account)
      assert only == second.id
      refute has_element?(live, "#rewrite-#{first.id}")
    end

    test "refuses a pattern PCRE cannot read, with its reason", %{
      conn: conn,
      post: post,
      user: user
    } do
      {:ok, live, _html} = live(conn, editor_path(post))

      html =
        live
        |> form("#rewrite-form", rule: %{pattern: "(a", replacement: ""})
        |> render_change()

      assert html =~ "not a valid regular expression"
      assert html =~ "missing closing parenthesis"

      live
      |> form("#rewrite-form", rule: %{pattern: "(a", replacement: ""})
      |> render_submit()

      assert PostRewrites.list_for_account(user, @account) == []
    end

    test "Done leads back to the page the member came from", %{conn: conn, post: post} do
      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("referer", "http://localhost:4001/feed?day=2026-09-01")
        |> live(editor_path(post))

      assert has_element?(live, ~s(#rewrite-done[href="/feed?day=2026-09-01"]))

      # A referer from elsewhere is not a page of ours to go back to.
      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("referer", "https://evil.example/feed")
        |> live(editor_path(post))

      assert has_element?(live, ~s(#rewrite-done[href="/feed"]))

      # An explicit return_to wins, as long as it is a local path.
      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("referer", "http://localhost:4001/feed")
        |> live(editor_path(post) <> "&return_to=/system/fediverse/post/#{post.id}")

      assert has_element?(live, ~s(#rewrite-done[href="/system/fediverse/post/#{post.id}"]))

      {:ok, live, _html} = live(conn, editor_path(post) <> "&return_to=//evil.example")
      assert has_element?(live, ~s(#rewrite-done[href="/feed"]))
    end

    test "a sample by another author is not shown, and an account with no posts has no preview",
         %{conn: conn, post: post} do
      {:ok, _live, html} =
        live(conn, ~p"/settings/rewrites/#{"@taz_de@flipboard.com"}?remote_post=#{post.id}")

      refute html =~ "Tablet Amazon"
      assert html =~ "There is no post by this account to preview your rules on."
    end

    test "a sample the reader may not see is not shown either", %{post: post} do
      # Followers-only, read by a member whose follow the account never
      # accepted: the link names a post they cannot see, and the account holds
      # nothing else they could.
      Repo.update!(Ecto.Changeset.change(post, audience: "followers"))

      {conn_other, _other} =
        create_and_login_user(
          Plug.Test.init_test_session(build_conn(), %{}),
          registration_attrs("other")
        )

      {:ok, _live, html} = live(conn_other, editor_path(post))
      refute html =~ "Tablet Amazon"
      assert html =~ "There is no post by this account to preview your rules on."
    end
  end

  describe "the index" do
    test "lists the accounts with rules and links into each", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = PostRewrites.create_rule(user, @account, %{pattern: "a"})
      {:ok, _} = PostRewrites.create_rule(user, @account, %{pattern: "b"})
      {:ok, _} = PostRewrites.create_rule(user, "@erika", %{pattern: "c"})

      {:ok, live, html} = live(conn, ~p"/settings/rewrites")

      assert html =~ "2 rules"
      assert html =~ "1 rule"

      assert has_element?(
               live,
               ~s(#rewrite-accounts a[href="/settings/rewrites/%40golemde%40flipboard.com"])
             )

      assert has_element?(live, ~s(#rewrite-accounts a[href="/settings/rewrites/%40erika"]))
    end

    test "says so when there are none", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, _live, html} = live(conn, ~p"/settings/rewrites")

      assert html =~ "You have no rules yet."
    end
  end
end
