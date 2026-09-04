defmodule VutuvWeb.PostThreadRemoteParentTest do
  @moduledoc """
  The post out there that a member's answer answers (issue #1165), on the
  **permalink** of that answer.

  The feed has drawn it above the answer since 2026-09-01; the permalink had
  only the "Replying to @user@host" line, and that line leads to the account,
  not to the post. So the one page a shared link to such an answer lands on was
  the page that showed half the exchange — which is what this covers, together
  with the audience question a public page has to ask before drawing somebody
  else's post, and the agent formats of that same page.

  Not async: answering a cached post claims from `Vutuv.RateLimiter`, a shared
  ETS table the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Posts

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  @remote "was da draussen steht"
  @answer "meine Antwort darauf"

  # A cached post from another network and a member's public answer to it.
  defp exchange do
    remote = cached_post(remote_account(), content_text: @remote)
    {:ok, post} = Posts.create_remote_post_reply(federating_member(), remote, %{body: @answer})

    {remote, post}
  end

  # The author narrowed their audience after the answer was written, and the
  # edit reached our copy — the one way a followers-only post ends up behind a
  # public answer, since writing that answer is refused
  # (`Fediverse.check_remote_post_reply/2`).
  defp narrow(remote),
    do: remote |> Ecto.Changeset.change(%{audience: "followers"}) |> Repo.update!()

  # The permalink's conversation, as the controller embeds it: signed out with
  # no cookie session, signed in with the one a login left behind.
  defp thread_view(post, cookie \\ %{}) do
    session = Map.merge(cookie, %{"post_id" => post.id, "locale" => "en"})

    live_isolated(build_conn(), VutuvWeb.PostLive.Thread, session: session)
  end

  defp member_session do
    {conn, user} = build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

    {user, Plug.Conn.get_session(conn)}
  end

  test "the post being answered is drawn above the answer, and takes its banner" do
    {remote, post} = exchange()
    {_reader, session} = member_session()

    {:ok, view, _html} = thread_view(post, session)
    html = render(view)

    assert html =~ @answer
    assert html =~ @remote
    assert :binary.match(html, @remote) < :binary.match(html, @answer)

    # The card above says what the line said, so the line goes: two of them is
    # the same fact twice, once as prose and once as the thing itself.
    refute has_element?(view, ~s([data-reply-banner="remote"]))

    # And the card is the way on to our copy's own page, which is what the
    # reader could not reach from here at all.
    assert has_element?(view, ~s(a[href="/system/fediverse/post/#{remote.id}"]))
  end

  test "a reader who is not signed in gets a public one too" do
    {_remote, post} = exchange()

    {:ok, view, _html} = thread_view(post)

    assert render(view) =~ @remote
  end

  test "a parent whose audience narrowed afterwards is not drawn on the public page" do
    {remote, post} = exchange()
    narrow(remote)

    {:ok, view, _html} = thread_view(post)
    html = render(view)

    refute html =~ @remote
    assert html =~ @answer

    # The line the card replaced is back, naming who was answered without
    # repeating what they wrote.
    assert has_element?(view, ~s([data-reply-banner="remote"]))
  end

  test "a signed-in follower still reads a followers-only parent" do
    {remote, post} = exchange()
    narrow(remote)

    {reader, session} = member_session()

    Repo.insert!(%Follow{
      user_id: reader.id,
      remote_account_id: remote.remote_account_id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{reader.id}/actor#f/#{remote.remote_account_id}"
    })

    {:ok, view, _html} = thread_view(post, session)

    assert render(view) =~ @remote
  end

  test "an expired copy is not drawn on the public page" do
    # The retention ceiling is the claim to hold somebody else's post at all,
    # so a row the sweep has not reached yet is not one to keep publishing —
    # the rule the tag timeline and the federated timeline already spell in SQL.
    # A copy survives its ceiling when a member here reshared it, which is
    # exactly a copy an answer can also hang off.
    {remote, post} = exchange()

    remote
    |> Ecto.Changeset.change(%{expires_at: DateTime.add(DateTime.utc_now(:second), -60)})
    |> Repo.update!()

    {:ok, view, _html} = thread_view(post)

    refute render(view) =~ @remote
  end

  test "the parent card's menu events are handled here" do
    # A surface that renders the cached card must handle all three of its ⋯
    # events — an unhandled `phx-click` takes the LiveView down, so a button
    # that kills the page is the failure this pins.
    {remote, post} = exchange()
    {_reader, session} = member_session()

    {:ok, view, _html} = thread_view(post, session)

    render_click(view, "mute-remote-account", %{"id" => remote.remote_account_id})
    render_click(view, "unfollow-remote-account", %{"id" => remote.remote_account_id})
    render_click(view, "report-remote-post", %{"id" => remote.id})

    # The report deleted our copy, so the card is gone and the answer stands
    # under the line again.
    html = render(view)
    refute html =~ @remote
    assert html =~ @answer
  end

  describe "agent formats" do
    test "the words the page draws travel with every format" do
      {_remote, post} = exchange()
      path = Posts.path(post)

      for extension <- ~w(md txt json xml) do
        assert get(build_conn(), "#{path}.#{extension}").resp_body =~ @remote,
               "the .#{extension} sibling withheld what the page shows"
      end
    end

    test "a parent the page may not draw is named but not quoted" do
      {remote, post} = exchange()
      narrow(remote)

      body = build_conn() |> get("#{Posts.path(post)}.md") |> response(200)

      refute body =~ @remote
      # The handle and the origin URI ride the sidecar, so they outlive both
      # the audience change and our copy itself.
      assert body =~ remote.remote_account.handle
    end
  end
end
