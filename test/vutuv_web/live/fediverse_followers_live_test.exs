defmodule VutuvWeb.FediverseFollowersLiveTest do
  @moduledoc """
  The member's remote-follower table (/settings/fediverse/followers): search as
  you type, the server filter, sortable columns, the inserted_at column and
  numbered paging, all over the socket with the view in the URL.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower

  defp follower(user, attrs) do
    host = attrs[:host] || "mastodon.example"
    handle = attrs[:handle] || "someone"

    Repo.insert!(%Follower{
      user_id: user.id,
      actor_uri: "https://#{host}/users/#{handle}",
      inbox_uri: "https://#{host}/users/#{handle}/inbox",
      handle: handle,
      name: attrs[:name]
    })
  end

  defp federating(conn) do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    {conn, user}
  end

  test "an anonymous visitor is sent away", %{conn: conn} do
    conn = get(conn, ~p"/settings/fediverse/followers")
    assert redirected_to(conn) == ~p"/"
  end

  test "a member who does not federate lands back on the switch", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/settings/fediverse/followers")
    assert to == ~p"/settings/fediverse"
  end

  test "with no followers at all it explains itself instead of showing a table", %{conn: conn} do
    {conn, _user} = federating(conn)

    {:ok, live, _html} = live(conn, ~p"/settings/fediverse/followers")

    assert has_element?(live, "#no-followers")
    refute has_element?(live, "#follower-filter")
    refute has_element?(live, "#followers")
  end

  describe "the table" do
    setup %{conn: conn} do
      {conn, user} = federating(conn)

      crse = follower(user, handle: "crse", name: "Christian Yoga", host: "social.linux.pizza")
      jti = follower(user, handle: "jti42", name: "JTI", host: "infosec.exchange")
      anon = follower(user, handle: "116862070468658358", host: "mastodon.social")

      {:ok, live, _html} = live(conn, ~p"/settings/fediverse/followers")

      %{conn: conn, live: live, user: user, crse: crse, jti: jti, anon: anon}
    end

    test "lists every follower with its handle and the date it arrived", %{
      live: live,
      crse: crse
    } do
      html = render(live)

      assert has_element?(live, "#follower-#{crse.id}")
      assert html =~ "@crse@social.linux.pizza"
      assert html =~ "Christian Yoga"
      # The "Following since" column: a <time> the client localizes.
      assert has_element?(live, "#followed-#{crse.id}")
      assert has_element?(live, "#sort-followed")
    end

    test "search narrows the table as you type", %{live: live, crse: crse, jti: jti} do
      live |> form("#follower-filter", %{"q" => "christian"}) |> render_change()

      assert has_element?(live, "#follower-#{crse.id}")
      refute has_element?(live, "#follower-#{jti.id}")

      # The view is in the URL, so it can be shared and the back button works.
      assert_patched(live, ~p"/settings/fediverse/followers?q=christian")
    end

    test "a pasted @user@server handle finds that one account", %{
      live: live,
      crse: crse,
      jti: jti
    } do
      live
      |> form("#follower-filter", %{"q" => "@crse@social.linux.pizza"})
      |> render_change()

      assert has_element?(live, "#follower-#{crse.id}")
      refute has_element?(live, "#follower-#{jti.id}")
    end

    test "a search matching nobody says so and offers a way out", %{live: live} do
      live |> form("#follower-filter", %{"q" => "nobody-here"}) |> render_change()

      assert has_element?(live, "#no-matches")
      assert has_element?(live, "#clear-filters")
      refute has_element?(live, "#followers")

      live |> element("#clear-filters") |> render_click()

      assert has_element?(live, "#followers")
      refute has_element?(live, "#no-matches")
    end

    test "the server dropdown filters to one server", %{live: live, jti: jti, crse: crse} do
      assert has_element?(live, "#filter-server option[value='infosec.exchange']")

      live |> form("#follower-filter", %{"server" => "infosec.exchange"}) |> render_change()

      assert has_element?(live, "#follower-#{jti.id}")
      refute has_element?(live, "#follower-#{crse.id}")
    end

    test "clicking a server in a row filters by it", %{live: live, jti: jti, crse: crse} do
      live
      |> element("#follower-#{jti.id} button[phx-click='filter_server']")
      |> render_click()

      assert has_element?(live, "#follower-#{jti.id}")
      refute has_element?(live, "#follower-#{crse.id}")
      assert_patched(live, ~p"/settings/fediverse/followers?server=infosec.exchange")
    end

    test "a column header sorts, and clicking it again reverses", %{live: live} do
      live |> element("#sort-account") |> render_click()
      assert_patched(live, ~p"/settings/fediverse/followers?sort=account")
      assert has_element?(live, "th[aria-sort='ascending'] #sort-account")

      live |> element("#sort-account") |> render_click()
      assert_patched(live, ~p"/settings/fediverse/followers?dir=desc&sort=account")
      assert has_element?(live, "th[aria-sort='descending'] #sort-account")
    end

    test "the arrival column starts newest first and reverses on a click", %{live: live} do
      assert has_element?(live, "th[aria-sort='descending'] #sort-followed")

      live |> element("#sort-followed") |> render_click()

      assert_patched(live, ~p"/settings/fediverse/followers?dir=asc")
      assert has_element?(live, "th[aria-sort='ascending'] #sort-followed")
    end

    # On a phone the card is ~310px wide; three columns would push "Following
    # since" past its edge. The server is already the tail of every handle, so
    # that column folds away below `sm` and the two facts a phone reader wants
    # (who, and since when) both fit.
    test "the server column folds away on a phone", %{live: live, crse: crse} do
      assert has_element?(live, "th.hidden.sm\\:table-cell #sort-server")
      assert has_element?(live, "#follower-#{crse.id} td.hidden.sm\\:table-cell")
    end

    test "one member never sees another's followers", %{live: live} do
      other = insert(:activated_user, fediverse_followers?: true)
      theirs = follower(other, handle: "not-mine", host: "elsewhere.example")

      refute has_element?(live, "#follower-#{theirs.id}")
      refute render(live) =~ "not-mine"
    end
  end

  describe "paging a long list" do
    setup %{conn: conn} do
      {conn, user} = federating(conn)
      per_page = Fediverse.browse_per_page()
      for n <- 1..(per_page + 3), do: follower(user, handle: "f#{1000 + n}")

      {:ok, live, _html} = live(conn, ~p"/settings/fediverse/followers")

      %{conn: conn, live: live, user: user, per_page: per_page}
    end

    test "shows one page at a time and says where you are", %{live: live, per_page: per_page} do
      html = render(live)

      rows =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("tbody#followers tr") |> Enum.count()

      assert rows == per_page
      assert html =~ "1-#{per_page}"
      assert has_element?(live, "nav a", "2")
    end

    test "the second page carries the rest, and keeps the active filter", %{conn: conn} do
      {:ok, live, _html} =
        live(conn, ~p"/settings/fediverse/followers?server=mastodon.example&page=2")

      rows =
        live
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tbody#followers tr")
        |> Enum.count()

      assert rows == 3
      assert has_element?(live, "#filter-server option[selected][value='mastodon.example']")
    end
  end

  # vutuv is a German site, so a page whose new strings have no German msgstr
  # renders as an English island for real visitors while every English check
  # stays green.
  test "the German render is German, not an English island", %{conn: conn} do
    {conn, user} = federating(conn)
    follower(user, handle: "one")

    {:ok, live, _html} =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> live(~p"/settings/fediverse/followers")

    html = render(live)

    assert html =~ "Folgt seit"
    assert html =~ "Alle Server"
    refute html =~ "Following since"
  end

  # The switch page used to repeat the newest few followers as a bare list right
  # above the link to this table, which says the same thing worse: no dates, no
  # search, no sort. It offers the link only now.
  test "the settings page links to the full list instead of previewing it", %{conn: conn} do
    {conn, user} = federating(conn)
    follower(user, handle: "one", name: "Someone Out There")

    html = conn |> get(~p"/settings/fediverse") |> html_response(200)

    assert html =~ ~s(href="#{~p"/settings/fediverse/followers"}")
    refute html =~ "Someone Out There"
    refute html =~ "@one@mastodon.example"
  end
end
