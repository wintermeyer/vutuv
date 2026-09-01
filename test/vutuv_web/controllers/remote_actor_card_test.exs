defmodule VutuvWeb.RemoteActorCardTest do
  @moduledoc """
  The card behind a `@user@host` mention in a post: who may open it, what it
  answers, and the follow round trip inside it
  (`VutuvWeb.RemoteActorCardController`).
  """
  # `async: false`: every test here stubs the Fediverse HTTP client through
  # `Application.put_env/3`, which is global and outlives no transaction.
  use VutuvWeb.ConnCase, async: false

  import Vutuv.FediverseHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount

  @actor "https://social.example/users/them"
  @address "them@social.example"

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "social.example",
      handle: "them",
      name: "Them Themself",
      summary: "Schreibt über Züge.",
      inbox_uri: @actor <> "/inbox"
    })
  end

  defp federating(conn) do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    {conn, user}
  end

  # A remote server that answers the actor document and nothing else. Any other
  # request is a request this card should not be making.
  defp serve_actor do
    stub_remote(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => @actor,
          "type" => "Person",
          "preferredUsername" => "them",
          "name" => "Them Themself",
          "inbox" => @actor <> "/inbox",
          "publicKey" => %{"id" => @actor <> "#main-key", "publicKeyPem" => "PEM"}
        })
      )
    end)
  end

  test "a visitor who is not signed in gets no card", %{conn: conn} do
    account()

    conn = post(conn, ~p"/system/fediverse/actor_card", address: @address)

    assert conn.status == 404
  end

  # The card may resolve an address this installation has never seen, which is
  # an outbound request to a host somebody else named in a post. As a GET that
  # would be a link, and a link is followed by prefetches and crawlers.
  test "there is no GET surface at all", %{conn: conn} do
    {conn, _user} = federating(conn)

    conn = get(conn, "/system/fediverse/actor_card?address=#{@address}")

    assert conn.status == 404
  end

  test "it names the account, offers the follow and keeps both ways onward", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "Them Themself"
    assert html =~ "@them@social.example"
    assert html =~ "Schreibt über Züge."
    assert html =~ ~s(data-actor-act="follow")
    # Their page here, and the original out there: a reader who does not want to
    # follow is never left in a box with one button.
    assert html =~ ~p"/system/fediverse/account/#{acc.id}"
    assert html =~ @actor
  end

  # The common case, and the reason the card is cheap: most accounts a member
  # meets in a post are already stored, because somebody here follows them or
  # something of theirs arrived. Calibrated by the stub, which fails the test if
  # any request goes out at all.
  test "an account we already hold costs no request", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    stub_remote(fn _conn -> raise "an account we already hold must not be fetched" end)

    assert post(conn, ~p"/system/fediverse/actor_card", address: @address)
           |> html_response(200) =~ "Them Themself"
  end

  test "the follow starts as requested and is taken back from the same card", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()
    serve_actor()

    html =
      post(conn, ~p"/system/fediverse/actor_card/follow", address: @address)
      |> html_response(200)

    # "Requested", not "Following": that server has not answered yet, and a card
    # that said otherwise would be a lie the member acts on.
    assert html =~ ~s(data-follow-state="requested")
    assert html =~ ~s(data-actor-act="unfollow")
    assert Repo.aggregate(Follow, :count) == 1

    html =
      conn
      |> delete(~p"/system/fediverse/actor_card/follow", address: @address)
      |> html_response(200)

    assert html =~ ~s(data-actor-act="follow")
    assert Repo.aggregate(Follow, :count) == 0
  end

  # Real visitors here send `Accept-Language: de`, and `Phoenix.ConnTest`
  # defaults to English — so the German render is its own case. Every word on
  # this card is an existing msgid rather than a new one (the same sentences the
  # account page and a looked-up post's card already say), and this is what
  # holds that: a new msgid would come back fuzzy-filled and read as confident
  # nonsense in German while every English assertion above stayed green.
  test "it reads German for a German reader", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    html =
      conn
      # The login already sent a response on this conn; a header goes on the
      # recycled one.
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> post(~p"/system/fediverse/actor_card", address: @address)
      |> html_response(200)

    assert html =~ "Konto in einem anderen Netzwerk"
    assert html =~ "Folgen"
    assert html =~ "Die Seite dieses Kontos hier"
    assert html =~ "Original ansehen"
  end

  test "a member without a Fediverse identity is told why, not shown a dead button", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ ~s(data-actor-act="follow")
    assert html =~ ~s(data-actor-card-error)
    assert html =~ "Fediverse"
  end

  # The fragment lands on a `<body>`-level node outside every LiveView root, so
  # two things in it would be quietly broken: a `<.link navigate>` (LiveView
  # binds those to an owning view, and there is none) and a fixed `id` (the card
  # can be open over a page that already renders the same element — the account
  # page renders the refusal panel this card deliberately does not). Hence
  # `follow_refusal_sentence/1` instead of `follow_refusal_panel/1`, and hence
  # this test, which is the only thing standing between the next author and a
  # dead link nobody notices.
  test "carries no live-navigation link and no id anybody else could own", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ "data-phx-link"
    refute html =~ ~s(id=)
  end

  # A fragment, not a page: both layouts are off. With only `put_layout` off the
  # `:browser` pipeline's root layout still wrapped every card in a whole HTML
  # document, and `innerHTML` unwraps that into the panel — 22 meta tags, six
  # stylesheet links and two scripts, re-fetched on every open, none of which a
  # substring assertion on the card's own words would ever notice.
  test "the answer is a fragment, not a document", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ "<html"
    refute html =~ "<meta"
    refute html =~ "<script"
    assert html =~ ~s(class="actor-card__content")
  end

  test "an address nobody can resolve still says why, and still leads out", %{conn: conn} do
    {conn, _user} = federating(conn)

    stub_remote(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    html =
      post(conn, ~p"/system/fediverse/actor_card", address: "nobody@social.example")
      |> html_response(200)

    assert html =~ ~s(data-actor-card-error)
    assert html =~ "https://social.example/@nobody"
    refute html =~ ~s(data-actor-act="follow")
  end
end
