defmodule VutuvWeb.FediverseFollowingLiveTest do
  @moduledoc """
  The page a member follows accounts on other networks from
  (/settings/fediverse/following, issue #1160): the add box, what each refusal
  says, the state column, unfollowing and the shared table machinery.

  `async: false` — the HTTP stub lives in the application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.EndpointHostHelper

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Social

  @actor_uri "https://social.example/users/them"

  defp stub_account do
    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        {type, body} =
          case conn.request_path do
            "/.well-known/webfinger" ->
              {"application/jrd+json",
               %{
                 "links" => [
                   %{"rel" => "self", "type" => "application/activity+json", "href" => @actor_uri}
                 ]
               }}

            _actor ->
              {"application/activity+json",
               %{
                 "id" => @actor_uri,
                 "type" => "Person",
                 "preferredUsername" => "them",
                 "name" => "Them",
                 "inbox" => "https://social.example/users/them/inbox"
               }}
          end

        conn
        |> Plug.Conn.put_resp_content_type(type)
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp federating(conn) do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    {conn, user}
  end

  test "an anonymous visitor is sent away", %{conn: conn} do
    conn = get(conn, ~p"/settings/fediverse/following")
    assert redirected_to(conn) == ~p"/"
  end

  test "a member who does not federate gets the reason and the switch", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

    # Explained on the spot, not redirected away from the page they asked for.
    assert has_element?(view, "#not-federating[data-reason=opted_out]")
    assert has_element?(view, "#enable-fediverse-link")
    refute has_element?(view, "#follow-form")
  end

  test "a member the moderation freezer holds is not told to flip a switch", %{conn: conn} do
    {conn, user} = federating(conn)
    {:ok, _} = Vutuv.Moderation.admin_freeze_user(user, insert(:user, admin?: true), "review")

    {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

    # Same false `federated?/1`, a completely different reason and way out.
    assert has_element?(view, "#not-federating[data-reason=restricted]")
    assert has_element?(view, "#moderation-cases-link")
    refute has_element?(view, "#enable-fediverse-link")
  end

  test "the German render is a German page", %{conn: conn} do
    stub_account()
    {conn, _user} = federating(conn)

    # A German visitor's real request, because a plain English one would hide a
    # German-only gap: `Phoenix.ConnTest` defaults to `en`.
    {:ok, view, html} =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> live(~p"/settings/fediverse/following")

    assert html =~ "Konten, denen Sie anderswo folgen"

    view |> element("#follow-form") |> render_submit(%{"address" => "@them@social.example"})

    # The state pill and the row control, in German and distinct from each other.
    rendered = render(view)
    assert rendered =~ "Angefragt"
    assert rendered =~ "Anfrage zurückziehen"
  end

  describe "following an account" do
    setup %{conn: conn} do
      stub_account()
      {conn, user} = federating(conn)
      %{conn: conn, user: user}
    end

    test "pasting an address adds the row as a request", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

      assert has_element?(view, "#no-following")

      view |> element("#follow-form") |> render_submit(%{"address" => "@them@social.example"})

      assert [follow] = Repo.all(from(f in Follow, where: f.user_id == ^user.id))
      assert follow.state == "requested"

      html = render(view)
      assert html =~ "@them@social.example"
      # The state is the truth, not "Following".
      assert has_element?(view, "[data-follow-state=requested]")
      assert has_element?(view, "#unfollow-#{follow.id}")
      refute has_element?(view, "#no-following")
    end

    test "an accepted follow reads differently", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")
      view |> element("#follow-form") |> render_submit(%{"address" => "@them@social.example"})

      [follow] = Repo.all(from(f in Follow, where: f.user_id == ^user.id))

      :ok =
        Fediverse.accept_remote_follow(
          user,
          %{"type" => "Accept", "object" => follow.follow_activity_id},
          @actor_uri
        )

      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")
      assert has_element?(view, "[data-follow-state=accepted]")
    end

    test "a refusal is explained next to the box", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

      view |> element("#follow-form") |> render_submit(%{"address" => "nonsense"})

      assert has_element?(view, "#follow-error")
      assert render(view) =~ "@name@server"

      # And it clears again as soon as the address is corrected.
      view |> element("#follow-form") |> render_change(%{"address" => "@them@social."})
      refute has_element?(view, "#follow-error")
    end

    test "unfollowing removes the row", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")
      view |> element("#follow-form") |> render_submit(%{"address" => "@them@social.example"})

      [follow] = Repo.all(from(f in Follow, where: f.user_id == ^user.id))

      view |> element("#unfollow-#{follow.id}") |> render_click()

      assert Repo.all(from(f in Follow, where: f.user_id == ^user.id)) == []
      assert has_element?(view, "#no-following")
    end

    test "the search box narrows the list and the URL carries the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")
      view |> element("#follow-form") |> render_submit(%{"address" => "@them@social.example"})

      view |> element("#following-filter") |> render_change(%{"q" => "nobody"})
      assert has_element?(view, "#no-matches")
      assert_patched(view, ~p"/settings/fediverse/following?q=nobody")

      view |> element("#clear-filters") |> render_click()
      assert_patched(view, ~p"/settings/fediverse/following")
      assert has_element?(view, "#following")
    end

    test "a sortable header rewrites the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")
      view |> element("#follow-form") |> render_submit(%{"address" => "@them@social.example"})

      view |> element("#sort-account") |> render_click()
      assert_patched(view, ~p"/settings/fediverse/following?sort=account")
    end

    test "an address handed over from the search page is prefilled, never followed", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} =
        live(conn, ~p"/settings/fediverse/following?#{[address: "@them@social.example"]}")

      assert has_element?(view, "#follow-address[value='@them@social.example']")
      # Arriving is a GET: nothing may have left the building yet.
      assert Repo.all(from(f in Follow, where: f.user_id == ^user.id)) == []
    end
  end

  describe "following an address that lives on this vutuv" do
    setup %{conn: conn} do
      # Any outbound request here would be vutuv resolving itself (issue #1211).
      Application.put_env(:vutuv, :fediverse_req_options,
        plug: fn _conn -> raise "our own members need no WebFinger lookup" end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)

      with_endpoint_host("vutuv.test")
      {conn, user} = federating(conn)
      %{conn: conn, user: user}
    end

    test "the member behind the address is followed on vutuv instead", %{conn: conn, user: user} do
      other = insert_activated_user()
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

      view
      |> element("#follow-form")
      |> render_submit(%{"address" => "@#{other.username}@vutuv.test"})

      assert Social.user_follows_user?(user.id, other.id)
      # No Fediverse row, no request row, no refusal: the box simply clears.
      assert Repo.all(from(f in Follow, where: f.user_id == ^user.id)) == []
      refute has_element?(view, "#follow-error")
      refute has_element?(view, "#follow-address[value^='@']")
    end

    test "one's own address is refused, in words", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

      view
      |> element("#follow-form")
      |> render_submit(%{"address" => "@#{user.username}@vutuv.test"})

      assert has_element?(view, "#follow-error")
      assert render(view) =~ "yourself"
      assert Repo.aggregate(Social.Follow, :count) == 0
    end

    test "the German member reads the German refusal", %{conn: conn, user: user} do
      {:ok, view, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/settings/fediverse/following")

      view
      |> element("#follow-form")
      |> render_submit(%{"address" => "@#{user.username}@vutuv.test"})

      assert render(view) =~ "nicht selbst folgen"
    end

    test "an unknown handle on this host still gets the search hand-off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/fediverse/following")

      view |> element("#follow-form") |> render_submit(%{"address" => "@ghost@vutuv.test"})

      assert has_element?(view, "#follow-error")
      assert has_element?(view, "#local-member-search")
    end
  end

  describe "the search page's offer" do
    test "a full address offers the follow flow", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/search?#{[q: "@them@social.example"]}")

      assert has_element?(view, "#search-remote-address")
      assert has_element?(view, "#search-remote-follow")
    end

    test "an ordinary query offers nothing of the sort", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/search?#{[q: "meier"]}")

      refute has_element?(view, "#search-remote-address")
    end

    test "a signed-out visitor is asked to sign in first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/search?#{[q: "@them@social.example"]}")

      assert has_element?(view, "#search-remote-login")
      refute has_element?(view, "#search-remote-follow")
    end
  end
end
