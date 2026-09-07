defmodule VutuvWeb.ThreadRepliesLastTest do
  @moduledoc """
  The unfolded answers are the last thing in the card they hang under.

  That is a layout precondition, not a preference. The thread's line comes down
  out of the answered avatar and is drawn to the bottom of `[data-card-head]`
  (`app.css`), because that element is the only one spanning from the avatar to
  the answers — so whatever is rendered after the answers is something the line
  runs on past, which is the exact complaint the connectors were rebuilt to fix.

  Two places had to move for this to hold: the action bar's own refusal notice,
  and the provenance footer of a reply card. Both are one line in a template and
  both would come back silently, so the promise is asserted rather than written
  down: this file reads the rendered card and fails if anything follows the
  answers.

  `async: false` for the reason `thread_replies_live_test.exs` gives — the press
  goes through the global `:fediverse_req_options` stub and the shared rate
  limiter.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  setup do
    Vutuv.RateLimiter.reset()

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 404, "") end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
    :ok
  end

  defp account(host \\ "ard.social", handle \\ "tagesschau") do
    uri = "https://#{host}/users/#{handle}#{System.unique_integer([:positive])}"

    Repo.insert!(%RemoteAccount{
      actor_uri: uri,
      host: host,
      handle: handle,
      name: handle,
      inbox_uri: uri <> "/inbox"
    })
  end

  defp follow(user, account) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp cached_post(account, attrs) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: account.id,
          object_uri: "https://#{account.host}/posts/#{System.unique_integer([:positive])}",
          content_text: "Welche Distro soll ich nehmen?",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  defp stored_answer(post, text) do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id:
        account("chaos.social", "somebody#{System.unique_integer([:positive])}").id,
      object_uri: "https://chaos.social/notes/#{System.unique_integer([:positive])}",
      in_reply_to_uri: post.object_uri,
      content_text: text,
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400),
      thread_context: true
    })
  end

  defp login_de(conn) do
    conn
    |> Plug.Conn.put_req_header("accept-language", "de-DE,de;q=0.9")
    |> create_and_login_user()
  end

  # Everything inside the answered card that renders after the answers. Read out
  # of the parsed document, so a template that merely reorders two siblings is
  # caught rather than a string that happens to appear later in the source.
  defp after_the_answers(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-card-head]:has([data-thread-replies]) [data-thread-replies] ~ *")
    |> Enum.to_list()
  end

  test "nothing in the card is rendered after the unfolded answers", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 1})
    stored_answer(post, "Nimm Mint.")

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()
    html = render_async(view)

    assert html =~ "Nimm Mint."

    assert after_the_answers(html) == [],
           "The thread's line is drawn to the bottom of the card, so anything " <>
             "rendered after the answers is something it runs on past. Put the " <>
             "new element above `<.thread_replies>` instead."
  end

  test "a refusal explains itself above the answers, not under them", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 1})
    stored_answer(post, "Nimm Mint.")

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()
    render_async(view)

    # This member does not federate, so the heart is refused and the bar
    # explains itself inline — the one element that really does render beside
    # an open thread, and the reason this file exists. Addressed by the answered
    # card's own bar, since every answer under it now carries one too.
    html =
      view
      |> element("#remote-actions-post-#{post.id}-like")
      |> render_click()

    assert has_element?(view, "[data-remote-notice]"),
           "The refusal has to be on the page for this test to prove anything."

    assert after_the_answers(html) == [],
           "The refusal notice belongs above the answers: below them it is one " <>
             "more row the thread's line runs down past."
  end
end
