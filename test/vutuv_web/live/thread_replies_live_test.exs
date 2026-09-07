defmodule VutuvWeb.ThreadRepliesLiveTest do
  @moduledoc """
  Pressing the answer figure on a card from another network, on the page that
  card links to.

  The control is two targets in one slot — a glyph that leads to the answering
  page, a figure that unfolds the thread — and the reason it is built that way
  is what these tests pin: the number is the button, and the two are far enough
  apart to hit separately.

  `async: false` — the fetch behind the press goes through the global
  `:fediverse_req_options` stub, and the hourly budget lives in the shared
  `Vutuv.RateLimiter` table, which the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  setup do
    Vutuv.RateLimiter.reset()
    # Nothing in these tests wants a real request; a press with no stub would
    # make one. An empty routing table answers 404 to everything, which is what
    # the "could not be fetched" path is.
    stub(%{})
    :ok
  end

  defp stub(routes) do
    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        url = "https://#{conn.host}#{conn.request_path}"

        case Map.fetch(routes, url) do
          {:ok, doc} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/activity+json")
            |> Plug.Conn.send_resp(200, Jason.encode!(doc))

          :error ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp account(host \\ "ard.social", handle \\ "tagesschau") do
    uri = "https://#{host}/users/#{handle}"

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

  defp cached_post(account, attrs \\ %{}) do
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

  # Logged in and reading in German, which is the language this site is
  # actually read in: `ConnTest` defaults to English, so a label asserted
  # without this header proves nothing about what a real visitor sees. The
  # header rides along from here because `recycle/1` carries `accept-language`
  # into every following request of the same conn.
  defp login_de(conn) do
    conn
    |> Plug.Conn.put_req_header("accept-language", "de-DE,de;q=0.9")
    |> create_and_login_user()
  end

  defp open_page(conn, post) do
    live(conn, ~p"/system/fediverse/post/#{post.id}")
  end

  test "the figure is a button of its own beside the answering glyph", %{conn: conn} do
    {conn, _user} = login_de(conn)
    post = cached_post(account(), %{replies_count: 7})

    {:ok, view, html} = open_page(conn, post)

    assert has_element?(view, ~s{[data-remote-replies="#{post.id}"]})
    assert has_element?(view, ~s{[data-remote-reply-link="#{post.id}"]})
    # The reader is told what the number means before they press it.
    assert html =~ "Die 7 Antworten anzeigen"
  end

  test "no figure where the origin never told us of any answer", %{conn: conn} do
    {conn, _user} = login_de(conn)
    post = cached_post(account())

    {:ok, view, _html} = open_page(conn, post)

    # The glyph stays — answering is always offered — and the figure does not
    # appear as a `0` we would be inventing.
    assert has_element?(view, ~s{[data-remote-reply-link="#{post.id}"]})
    refute has_element?(view, ~s{[data-remote-replies="#{post.id}"]})
  end

  test "pressing it unfolds what we already hold, without asking anybody", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 1})
    stored_answer(post, "Nimm Mint.")

    {:ok, view, _html} = open_page(conn, post)
    refute has_element?(view, "[data-thread-replies]")

    html = view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()

    assert html =~ "Nimm Mint."
    assert has_element?(view, "[data-thread-replies]")
  end

  test "a second press folds the thread again", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 1})
    stored_answer(post, "Nimm Mint.")

    {:ok, view, _html} = open_page(conn, post)
    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()
    render_async(view)
    assert has_element?(view, "[data-thread-replies]")

    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()
    refute has_element?(view, "[data-thread-replies]")
  end

  test "an unreachable origin says so instead of leaving an empty box", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 3})

    {:ok, view, _html} = open_page(conn, post)
    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()

    assert render_async(view) =~ "Die Antworten ließen sich nicht"
  end

  test "an answer inside the thread offers no thread of its own", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 1})
    answer = stored_answer(post, "Nimm Mint.")

    # The answer has answers of its own out there, and its card still says so —
    # it just cannot be pressed, or a thread would nest inside a thread.
    Repo.update_all(from(p in RemotePost, where: p.id == ^answer.id), set: [replies_count: 4])

    {:ok, view, _html} = open_page(conn, post)
    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()
    html = render_async(view)

    assert html =~ "Nimm Mint."
    refute has_element?(view, ~s{[data-remote-replies="#{answer.id}"]})
  end

  test "every answer is tied into the line coming down from the card it answers", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 2})
    one = stored_answer(post, "Nimm Mint.")
    two = stored_answer(post, "Oder Salbei.")

    {:ok, view, _html} = open_page(conn, post)
    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()
    render_async(view)

    # A connector inside each answer, not two of them somewhere on the page.
    # Without them the thread is a rule standing beside the cards, touching
    # neither the card above nor the answers.
    for answer <- [one, two] do
      assert has_element?(view, ~s{[data-thread-reply="#{answer.id}"] [data-thread-tick]})
    end
  end

  test "the answers are drawn in the avatar column of the card above them", %{conn: conn} do
    {conn, user} = login_de(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc, %{replies_count: 1})
    stored_answer(post, "Nimm Mint.")

    {:ok, view, _html} = open_page(conn, post)
    view |> element(~s{[data-remote-replies="#{post.id}"]}) |> render_click()
    render_async(view)

    # The block sits inside the card's text column, so it has to pull back over
    # the avatar column (36px avatar + 12px gap) before its connectors can be
    # drawn in the column the card's own line comes down in.
    assert has_element?(view, "[data-thread-replies].-ml-12"),
           "The answers must reclaim the avatar column, or the thread line hangs " <>
             "between two columns and connects neither."

    refute has_element?(view, "[data-thread-replies].border-l-2"),
           "The thread is drawn as a line out of the avatar above and a connector " <>
             "into each answer, not as a rule on the block's own left edge."
  end
end
