defmodule VutuvWeb.PostLive.FeedNewcomersTest do
  @moduledoc """
  The feed rail's "New here" card: five of the newest members who show a face,
  drawn at random, each with how long they have been here and three of their
  tags.

  It replaced a most-followed suggestion rail, so what these tests hold down is
  the swap — only members with a picture the moderation scan released, never
  the viewer, anyone they already follow or anyone blocked either way, and the
  behaviour the ranked rail did *not* have: a greeted member stays on the card
  instead of vanishing on the click.
  """

  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Tags.UserTag

  # A member the card may draw: confirmed, with an avatar no scan is holding.
  # Newest-first ordering is by the UUID v7 primary key, so insertion order is
  # registration order and no `inserted_at` juggling is needed.
  defp newcomer(attrs \\ []) do
    insert(:activated_user, Keyword.put_new(attrs, :avatar, "selfie.jpg"))
  end

  # `count` tags on `user`, answering with their slugs — what the rendered chips
  # link to.
  defp tag_up(user, count) do
    for _ <- 1..count do
      user_tag = insert(:user_tag, user: user, tag: insert(:tag))
      UserTag.tag(user_tag).slug
    end
  end

  # Whether `user`'s row on the card carries a chip for `slug`. Scoped to the
  # row's own marker, so a chip belonging to the "Tags you follow" rail (or to
  # another newcomer) cannot satisfy the count.
  defp tag_chip?(view, user, slug) do
    has_element?(view, ~s([data-newcomer-tags="#{user.id}"] a[href="/tags/#{slug}"]))
  end

  describe "who the card draws" do
    test "greets the newest members who show a face", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      faceless = newcomer(avatar: nil)
      shown = newcomer()

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, ~s(#newcomers a[href="/#{shown.username}"]))
      refute has_element?(view, ~s(#newcomers a[href="/#{faceless.username}"]))
    end

    test "offers only an avatar the image scan released", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      # `Vutuv.Avatar.display_url/2` answers the default silhouette for anything
      # the scan has not released, so a card whose premise is faces must not
      # offer one. The gate is `ImageScans.released?/1`'s rule — nil (the
      # grandfathered state) or "approved" — and this pins the *rule*, not the
      # state list: `held` is a state that reaches no row today (a rejection
      # clears the column and the file together), so a gate spelled "anything
      # but pending" passes every other assertion here and fails this one,
      # which is the whole point of it.
      pending = newcomer(avatar_moderation: "pending")
      held = newcomer(avatar_moderation: "quarantined")
      released = newcomer(avatar_moderation: "approved")

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, ~s(#newcomers a[href="/#{released.username}"]))
      refute has_element?(view, ~s(#newcomers a[href="/#{pending.username}"]))
      refute has_element?(view, ~s(#newcomers a[href="/#{held.username}"]))
    end

    test "leaves out the viewer, the already-followed and the blocked", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      me = me |> Ecto.Changeset.change(avatar: "mine.jpg") |> Repo.update!()

      followed = newcomer()
      blocked = newcomer()
      free = newcomer()

      follow!(me, followed)
      {:ok, _block} = Social.block_user(me, blocked)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, ~s(#newcomers a[href="/#{free.username}"]))
      refute has_element?(view, ~s(#newcomers a[href="/#{followed.username}"]))
      refute has_element?(view, ~s(#newcomers a[href="/#{blocked.username}"]))
      refute has_element?(view, ~s(#newcomers a[href="/#{me.username}"]))
    end

    test "draws a different five each visit", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      # More newcomers than the five shown, so the card has to pick — and the
      # pick has to be a draw, not the top of a list. A fixed "newest five"
      # would show the same set on every visit however often you looked.
      pool = for _ <- 1..12, do: newcomer()

      shown =
        Enum.reduce(1..10, MapSet.new(), fn _visit, seen ->
          {:ok, view, _html} = live(recycle(conn), ~p"/feed")

          pool
          |> Enum.filter(&has_element?(view, ~s(#newcomers a[href="/#{&1.username}"])))
          |> Enum.reduce(seen, &MapSet.put(&2, &1.id))
        end)

      assert MapSet.size(shown) > 5
    end

    test "no card at all when there is nobody new to greet", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "#newcomers")
    end
  end

  describe "what a row says" do
    test "shows three of the tags and links to the rest", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      newbie = newcomer()
      slugs = tag_up(newbie, 5)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert Enum.count(slugs, &tag_chip?(view, newbie, &1)) == 3

      assert has_element?(
               view,
               ~s([data-newcomer-tags="#{newbie.id}"] a[href="/#{newbie.username}/tags"])
             )

      assert render(view) =~ "+2"
    end

    test "no overflow link when three tags are all of them", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      newbie = newcomer()
      slugs = tag_up(newbie, 3)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert Enum.count(slugs, &tag_chip?(view, newbie, &1)) == 3

      refute has_element?(
               view,
               ~s([data-newcomer-tags="#{newbie.id}"] a[href="/#{newbie.username}/tags"])
             )
    end

    test "shows the job title, and nothing where there is none", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      employed = newcomer()
      insert(:work_experience, user: employed, title: "Zugführerin", organization: "DB")
      jobless = newcomer()

      {:ok, view, _html} = live(conn, ~p"/feed")
      html = render(view)

      assert html =~ "Zugführerin"
      # The row is a name and its tags, not a name and an empty line: the meta
      # paragraph is absent rather than blank, so a member who has filled
      # nothing in yet costs the card no height.
      assert has_element?(view, "#newcomer-#{jobless.id}")
      refute html =~ "dabei ·"
    end

    test "says what the card is, in German", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      me |> Ecto.Changeset.change(locale: "de") |> Repo.update!()
      newcomer()

      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")
      {:ok, view, _html} = live(conn, ~p"/feed")
      html = render(view)

      # Named one by one because `gettext.extract --merge` fuzzy-fills a new
      # msgid with the translation of whatever it looks similar to, and short
      # labels like these are its favourite victims — a German feed would then
      # ship confident nonsense while every English assertion stayed green.
      assert html =~ "Neu dabei"
      assert html =~ "Ein paar der neuesten Mitglieder"
      assert html =~ "Ihnen zu folgen ist eine herzliche Begrüßung"
      # "zuletzt dazugekommen" promised an order the ↻ visibly contradicts.
      refute html =~ "zuletzt dazugekommen"
    end
  end

  describe "welcoming somebody" do
    test "the greeted row stays, flipped to Following", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      newbie = newcomer()

      {:ok, view, _html} = live(conn, ~p"/feed")

      view
      |> element(~s(#newcomer-#{newbie.id} button[phx-click="follow"]))
      |> render_click()

      # The point of the card: the member you just welcomed is still there,
      # wearing the answer, rather than replaced by a stranger.
      assert has_element?(view, ~s(#newcomer-#{newbie.id} button[phx-click="unfollow"]))
      assert Social.user_follows_user?(me.id, newbie.id)
    end

    test "and the welcome can be taken back on the spot", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      newbie = newcomer()

      {:ok, view, _html} = live(conn, ~p"/feed")

      view |> element(~s(#newcomer-#{newbie.id} button[phx-click="follow"])) |> render_click()
      view |> element(~s(#newcomer-#{newbie.id} button[phx-click="unfollow"])) |> render_click()

      assert has_element?(view, ~s(#newcomer-#{newbie.id} button[phx-click="follow"]))
      refute Social.user_follows_user?(me.id, newbie.id)
    end

    test "a fresh draw leaves the greeted member out", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      newbie = newcomer()
      other = newcomer()

      {:ok, view, _html} = live(conn, ~p"/feed")

      view |> element(~s(#newcomer-#{newbie.id} button[phx-click="follow"])) |> render_click()
      view |> element("#newcomers-reshuffle") |> render_click()

      refute has_element?(view, "#newcomer-#{newbie.id}")
      assert has_element?(view, "#newcomer-#{other.id}")
    end
  end

  test "the periodic tick redraws a filled card", %{conn: conn} do
    {conn, _me} = create_and_login_user(conn)
    newbie = newcomer()

    {:ok, view, _html} = live(conn, ~p"/feed")

    send(view.pid, :refresh_suggestions)
    render(view)

    assert has_element?(view, "#newcomer-#{newbie.id}")
  end
end
