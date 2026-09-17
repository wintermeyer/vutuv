defmodule VutuvWeb.MemberCardTest do
  @moduledoc """
  The card behind an `@handle` of our own (`VutuvWeb.MemberCardController`):
  who may open it, what it shows, the viewer's private notes on it, and the
  follow round trip inside it.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.MastodonHelpers, only: [remote_account: 1]

  alias Vutuv.PersonalNotes
  alias Vutuv.Social

  # The same reference `VutuvWeb.Markdown` writes on a mention.
  defp ref(%Vutuv.Accounts.User{username: handle}), do: "member:" <> handle
  defp ref(%Vutuv.Organizations.Organization{username: handle}), do: "organization:" <> handle

  defp page(attrs),
    do: insert(:organization, [username: "page#{System.unique_integer([:positive])}"] ++ attrs)

  defp open(conn, account), do: post(conn, ~p"/system/member_card", account: ref(account))

  defp note!(author, subject, body) do
    {:ok, note} = PersonalNotes.create(author, subject, %{"body" => body})
    note
  end

  defp doc(conn), do: conn |> html_response(200) |> LazyHTML.from_fragment()

  test "a visitor who is not signed in gets no card", %{conn: conn} do
    ada = insert_activated_user()

    assert conn |> open(ada) |> Map.fetch!(:status) == 404
  end

  test "there is no GET surface", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    ada = insert_activated_user()

    conn = get(conn, "/system/member_card?account=#{ref(ada)}")

    assert conn.status == 404
  end

  test "it names the member, offers the follow and links the profile", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)

    ada =
      insert_activated_user(%{
        first_name: "Ada",
        last_name: "Lovelace",
        headline: "**Math** first"
      })

    html = conn |> open(ada) |> html_response(200)

    # A fragment, not a document.
    refute html =~ "<html"
    assert html =~ "Ada Lovelace"
    assert html =~ "@#{ada.username}"
    # The tagline as words, not markup.
    assert html =~ "Math first"
    refute html =~ "**Math**"
    assert html =~ ~s(data-actor-act="follow")
    assert html =~ ~s(href="/#{ada.username}")
    # No notes yet: the way to a first one, and no quoted tiles.
    refute html =~ "data-actor-card-notes="
    assert html =~ ~s(href="/system/notes?member=#{ada.id}")
    assert html =~ "Add a personal note"
  end

  test "it quotes the viewer's newest notes and nobody else's", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user()
    other = insert_activated_user()

    note!(other, ada, "somebody else's note")
    for n <- 1..4, do: note!(viewer, ada, "note number #{n}")

    document = conn |> open(ada) |> doc()
    tiles = LazyHTML.query(document, "[data-actor-card-notes] .actor-card__latest")

    assert Enum.map(tiles, &(&1 |> LazyHTML.text() |> String.contains?("note number"))) ==
             [true, true, true]

    text = LazyHTML.text(document)
    assert text =~ "note number 4"
    refute text =~ "note number 1"
    refute text =~ "somebody else"
    assert text =~ "All 4 notes"
  end

  test "following and unfollowing round-trip inside the card", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user()

    followed = post(conn, ~p"/system/member_card/follow", account: ref(ada))
    assert html_response(followed, 200) =~ ~s(data-actor-act="unfollow")
    assert Social.follow_id(viewer.id, ada.id)

    unfollowed = delete(conn, ~p"/system/member_card/follow", account: ref(ada))
    assert html_response(unfollowed, 200) =~ ~s(data-actor-act="follow")
    refute Social.follow_id(viewer.id, ada.id)
  end

  test "a member's own card offers neither a follow nor notes", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)

    html = conn |> open(viewer) |> html_response(200)

    refute html =~ "data-actor-act"
    refute html =~ "/system/notes"
    assert html =~ "Your profile"

    post(conn, ~p"/system/member_card/follow", account: ref(viewer))
    refute Social.follow_id(viewer.id, viewer.id)
  end

  test "a block in either direction answers 404, so the link is followed", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    blocked = insert_activated_user()
    blocker = insert_activated_user()

    Social.block_user(viewer, blocked)
    Social.block_user(blocker, viewer)

    assert open(conn, blocked).status == 404
    assert open(conn, blocker).status == 404
    assert post(conn, ~p"/system/member_card/follow", account: ref(blocker)).status == 404
  end

  test "an unconfirmed member and a malformed reference answer 404", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    pending = insert(:user)

    assert open(conn, pending).status == 404
    assert post(conn, ~p"/system/member_card", account: "member:nobody_here").status == 404
    assert post(conn, ~p"/system/member_card", account: "remote_account:x").status == 404
    assert post(conn, ~p"/system/member_card", account: "nope").status == 404
  end

  test "a page gets the same card, with its own follow", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    page = page(name: "Analytical Engines", description: "We build *engines*.")
    note!(viewer, page, "Jana does their press")

    html = conn |> open(page) |> html_response(200)

    assert html =~ "Analytical Engines"
    assert html =~ "We build engines."
    assert html =~ "Jana does their press"
    assert html =~ "Their page"

    post(conn, ~p"/system/member_card/follow", account: ref(page))
    assert Social.follows_organization?(viewer, page)

    delete(conn, ~p"/system/member_card/follow", account: ref(page))
    refute Social.follows_organization?(viewer, page)
  end

  test "a frozen page answers 404", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    page = page(frozen_at: NaiveDateTime.utc_now(:second))

    assert open(conn, page).status == 404
  end

  # The remote card carries the same notes, read from the same summary.
  test "the remote card quotes the viewer's notes too", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    handle = "notes#{System.unique_integer([:positive])}"
    account = remote_account(handle: handle)
    note!(viewer, account, "asked for personal notes")

    html =
      conn
      |> post(~p"/system/fediverse/actor_card", address: "#{handle}@#{account.host}")
      |> html_response(200)

    assert html =~ "asked for personal notes"
    assert html =~ ~s(href="/system/notes?remote_account=#{account.id}")
  end
end
