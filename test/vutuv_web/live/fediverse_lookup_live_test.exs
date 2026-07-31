defmodule VutuvWeb.FediverseLookupLiveTest do
  @moduledoc """
  The lookup page (`/system/fediverse/lookup`, issue #1211): who may open it,
  what a pasted URL does, and what the result carries.

  `async: false` — the per-member lookup budget and the HTTP stub both live in
  application/ETS state the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @author "https://weit.example/users/autorin"
  @object "https://weit.example/users/autorin/statuses/7"
  @display "https://weit.example/@autorin/7"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp federating(conn) do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    {conn, Repo.reload!(user)}
  end

  defp serve do
    note = %{
      "id" => @object,
      "type" => "Note",
      "attributedTo" => @author,
      "url" => @display,
      "content" => "<p>Etwas, das lange vor dem Folgen geschrieben wurde.</p>",
      "published" => "2026-06-11T09:00:00Z",
      "to" => [@public]
    }

    actor = %{
      "id" => @author,
      "type" => "Person",
      "preferredUsername" => "autorin",
      "name" => "Die Autorin",
      "inbox" => @author <> "/inbox"
    }

    # The follow the result card offers starts at WebFinger, so the stub answers
    # that too rather than handing the resolver a Note.
    webfinger = %{
      "subject" => "acct:autorin@weit.example",
      "links" => [%{"rel" => "self", "type" => "application/activity+json", "href" => @author}]
    }

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        body =
          case conn.request_path do
            "/.well-known/webfinger" -> webfinger
            "/users/autorin" -> actor
            _post -> note
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  test "an anonymous visitor is sent away", %{conn: conn} do
    conn = get(conn, ~p"/system/fediverse/lookup")
    assert redirected_to(conn) == ~p"/login"
  end

  test "robots are told not to index it", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, ~p"/system/fediverse/lookup")

    assert [robots] = Plug.Conn.get_resp_header(conn, "x-robots-tag")
    assert robots =~ "noindex"
  end

  test "a member who does not federate gets the switch, not the box", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")

    assert has_element?(view, "#lookup-refusal[data-reason='not_federating']")
    assert has_element?(view, "#lookup-refusal-link")
    refute has_element?(view, "#lookup-form")
  end

  test "a pasted post URL renders the post with its action bar", %{conn: conn} do
    serve()
    {conn, _user} = federating(conn)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")
    assert has_element?(view, "#lookup-form")

    html = view |> element("#lookup-form") |> render_submit(%{"url" => @display})

    assert html =~ "Etwas, das lange vor dem Folgen geschrieben wurde."
    assert has_element?(view, "#lookup-result")

    post = Repo.get_by!(RemotePost, object_uri: @object)
    assert has_element?(view, "[data-remote-post='#{post.id}']")
    # The three acts the card carries, all reaching a post that was never
    # delivered here.
    assert has_element?(view, "[data-remote-act='like']")
    assert has_element?(view, "[data-remote-act='repost']")
    assert has_element?(view, "[data-remote-reply-link='#{post.id}']")
  end

  test "the author can be followed from the result", %{conn: conn} do
    serve()
    {conn, user} = federating(conn)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")
    view |> element("#lookup-form") |> render_submit(%{"url" => @display})

    assert has_element?(view, "#follow-author")
    view |> element("#follow-author") |> render_click()

    account = Repo.get_by!(RemoteAccount, actor_uri: @author)
    assert Repo.get_by(Follow, user_id: user.id, remote_account_id: account.id)
    assert has_element?(view, "[data-follow-state='requested']")
  end

  test "muting is not offered for an account the member does not follow", %{conn: conn} do
    serve()
    {conn, _user} = federating(conn)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")
    view |> element("#lookup-form") |> render_submit(%{"url" => @display})

    # A mute writes to a follow row that is not there, so the control would do
    # nothing under a flash claiming it did.
    refute has_element?(view, "[phx-click='mute-remote-account']")
  end

  test "the heart works on the looked-up post", %{conn: conn} do
    serve()
    {conn, user} = federating(conn)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")
    view |> element("#lookup-form") |> render_submit(%{"url" => @display})

    view |> element("[data-remote-act='like']") |> render_click()

    post = Repo.get_by!(RemotePost, object_uri: @object)
    assert MapSet.member?(Fediverse.liked_remote_post_ids(user, [post.id]), post.id)
    assert has_element?(view, "button[data-remote-act='like']")
  end

  test "a refused URL says why and shows no card", %{conn: conn} do
    {conn, _user} = federating(conn)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")
    html = view |> element("#lookup-form") |> render_submit(%{"url" => "was ist das"})

    assert has_element?(view, "#lookup-error")
    assert html =~ "https://server/@name/12345"
    refute has_element?(view, "#lookup-result")
  end

  test "a pasted account address is handed to the follow box", %{conn: conn} do
    {conn, _user} = federating(conn)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#lookup-form") |> render_submit(%{"url" => "@autorin@weit.example"})

    assert to =~ "/settings/fediverse/following?address="
  end

  test "a pasted vutuv post URL goes to its permalink", %{conn: conn} do
    {conn, _user} = federating(conn)
    author = insert(:activated_user)
    post = insert(:post, user: author)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/lookup")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("#lookup-form")
             |> render_submit(%{
               "url" => "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"
             })

    assert to == "/#{author.username}/posts/#{post.id}"
  end

  test "it reads German for a German visitor, refusal included", %{conn: conn} do
    serve()
    {conn, _user} = federating(conn)

    # A German visitor's real request. `Phoenix.ConnTest` defaults to `en`, so
    # an English-only check would hide a missing or fuzzy-filled translation on
    # the very page whose short labels are likeliest to get one.
    {:ok, view, html} =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> live(~p"/system/fediverse/lookup")

    assert html =~ "Einen Beitrag aus einem anderen Netzwerk nachschlagen"
    assert html =~ "Adresse des Beitrags"

    rendered = view |> element("#lookup-form") |> render_submit(%{"url" => "kein link"})
    assert rendered =~ "Das sieht nicht nach dem Link zu einem Beitrag aus."

    rendered = view |> element("#lookup-form") |> render_submit(%{"url" => @display})
    assert rendered =~ "Wer das geschrieben hat"
  end

  test "a German visitor who does not federate gets the German switch", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, _view, html} =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> live(~p"/system/fediverse/lookup")

    assert html =~ "Fediverse-Teilnahme einschalten, um nachzuschlagen"
    assert html =~ "Fediverse-Einstellungen"
  end

  test "the following page points here", %{conn: conn} do
    {conn, _user} = federating(conn)

    {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

    assert has_element?(view, "#fediverse-lookup-link[href='/system/fediverse/lookup']")
  end
end
