defmodule VutuvWeb.PostRewritesHostsTest do
  @moduledoc """
  The reader's per-author search-and-replace rules on the pages beyond the feed
  that draw a post card: a cached post's own page, the account page behind it,
  and a member post's permalink.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.Follow
  alias Vutuv.PostRewrites
  alias Vutuv.Posts

  @footer "Gepostet in GOLEM @golem-Golemde"

  setup %{conn: conn} do
    {conn, reader} = create_and_login_user(conn)

    account =
      remote_account(
        actor_uri: "https://flipboard.com/@Golemde",
        handle: "Golemde",
        name: "Golem.de"
      )

    Repo.insert!(%Follow{
      user_id: reader.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{reader.id}/actor#follows/hosts"
    })

    post = cached_post(account, content_text: "Dyson stellt Zahnbürste vor\n\n" <> @footer)

    {:ok, _rule} =
      PostRewrites.create_rule(reader, "@golemde@flipboard.com", %{pattern: "^Gepostet in .*$"})

    %{conn: conn, reader: reader, account: account, post: post}
  end

  test "the cached post's own page shows the rewritten text", %{conn: conn, post: post} do
    {:ok, live, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
    card = live |> element(~s([data-remote-post="#{post.id}"])) |> render()

    assert card =~ "Dyson stellt Zahnbürste vor"
    refute card =~ "Gepostet in"
  end

  test "the account page shows the rewritten text", %{conn: conn, account: account, post: post} do
    {:ok, live, _html} = live(conn, ~p"/system/fediverse/account/#{account.id}")
    card = live |> element(~s([data-remote-post="#{post.id}"])) |> render()

    assert card =~ "Dyson stellt Zahnbürste vor"
    refute card =~ "Gepostet in"
  end

  test "a member post's permalink shows the rewritten text", %{conn: conn, reader: reader} do
    author = insert(:activated_user, username: "erika-permalink")
    theirs = insert(:post, user: author, body: "Hallo zusammen -- Gruß Erika")
    {:ok, _} = PostRewrites.create_rule(reader, "@erika-permalink", %{pattern: " -- Gruß Erika"})

    html = conn |> get(Posts.path(theirs)) |> html_response(200)

    # The permalink renders the whole body (no clamp, no per-entry id), and
    # this conversation holds one post, so its body is the page's only one.
    body =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-post-body]")
      |> LazyHTML.text()

    assert body =~ "Hallo zusammen"
    refute body =~ "Gruß Erika"
  end
end
