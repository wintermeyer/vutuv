defmodule VutuvWeb.UserProfileFediverseTest do
  @moduledoc """
  The profile's Fediverse card and its "Follow from your own server" button:
  what a visitor arriving from Mastodon and friends sees, and what happens when
  they hand us their own address. Not async — the installation switch and the
  HTTP stub for the remote WebFinger lookup both live in the application env.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.EndpointHostHelper

  alias Vutuv.Social
  alias VutuvWeb.Fediverse.Docs

  @card "#profile-fediverse"
  @handle "#profile-fediverse-handle"
  @form "#remote-follow-form"
  @shortcut "#profile-fediverse-shortcut"

  defp federating_member(attrs \\ []) do
    insert_activated_user(Keyword.merge([fediverse_followers?: true], attrs))
  end

  defp position(html, id) do
    {at, _len} = :binary.match(html, ~s|id="#{id}"|)
    at
  end

  defp stub_remote(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp serve_subscribe_template do
    stub_remote(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/jrd+json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "links" => [
            %{
              "rel" => "http://ostatus.org/spec/1.0#subscribe",
              "template" => "https://social.example/authorize_interaction?uri={uri}"
            }
          ]
        })
      )
    end)
  end

  describe "the card" do
    test "shows a federating member's handle to a logged-out visitor", %{conn: conn} do
      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, @card)
      assert render(view) =~ Docs.handle(user)
      assert has_element?(view, @form)
    end

    test "is absent for a member who does not federate", %{conn: conn} do
      user = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      refute has_element?(view, @card)
    end

    test "is absent while the installation switch is off", %{conn: conn} do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      refute has_element?(view, @card)
    end

    test "points at the forwarding address once the member moved away", %{conn: conn} do
      user = federating_member(moved_to: "https://social.example/users/greta")

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, "#fediverse-moved-to")
      assert render(view) =~ "@greta@social.example"
      # Following here would land on a redirect, so the tool is not offered.
      refute has_element?(view, @form)
      refute has_element?(view, @handle)
    end

    test "closes the page, below the member's own cards", %{conn: conn} do
      user = federating_member()
      {:ok, _follow} = Social.follow(insert_activated_user(), user.id)

      {:ok, view, html} = live(conn, ~p"/#{user}")

      # The follower/following pair is the last block of the main content
      # column, and the rail follows it in the DOM: a card between the two is
      # the foot of the column on a desktop.
      assert position(html, "profile-fediverse") > position(html, "profile-followers")
      assert position(html, "profile-fediverse") < position(html, "profile-other-formats")

      # On a phone every card is one flex child of a single column, so the
      # order utility is what puts it below the rail's cards there.
      assert has_element?(view, "#profile-fediverse.order-3")
    end

    test "the form posts to the route that exists", %{conn: conn} do
      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert view
             |> element(@form)
             |> render() =~ ~s|action="/#{user.username}/fediverse/follow"|
    end
  end

  describe "the shortcut in the Profiles card" do
    test "names the address and points at the card", %{conn: conn} do
      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, "#profile-social-media " <> @shortcut)
      assert view |> element(@shortcut) |> render() =~ Docs.handle(user)
      assert view |> element(@shortcut) |> render() =~ ~s|href="#profile-fediverse"|
    end

    test "does not repeat the card's tools", %{conn: conn} do
      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      # The point of the shortcut is that the explanation, the copy button and
      # the remote-follow form exist once, at the foot of the page. A second
      # copy up here would be the heavy version this replaced.
      refute has_element?(view, "#profile-social-media #remote-follow-form")
      refute has_element?(view, "#profile-social-media [data-copy]")
    end

    test "the card it points at clears the sticky top bar", %{conn: conn} do
      user = federating_member()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, "#profile-fediverse.scroll-mt-24")
    end

    test "shows the forwarding address once the member moved away", %{conn: conn} do
      user = federating_member(moved_to: "https://social.example/users/greta")

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert view |> element(@shortcut) |> render() =~ "@greta@social.example"
    end

    test "is absent for a member who does not federate", %{conn: conn} do
      user = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      refute has_element?(view, @shortcut)
    end
  end

  describe "POST /:slug/fediverse/follow" do
    test "sends the visitor to their own server's follow dialog", %{conn: conn} do
      user = federating_member()
      serve_subscribe_template()

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) ==
               "https://social.example/authorize_interaction?uri=" <>
                 URI.encode_www_form("acct:" <> Docs.acct(user))
    end

    test "the token the rendered form carries really passes CSRF", %{conn: conn} do
      user = federating_member()
      serve_subscribe_template()

      # ConnTest skips CSRF on a plain post/3, so the one thing worth proving
      # here is that the token a LiveView-rendered form stamps is accepted: the
      # profile is rendered by a LiveView, which loads the session's CSRF state
      # separately from the controller.
      conn = get(conn, ~p"/#{user}")

      conn =
        submit_with_csrf(conn, ~p"/#{user}/fediverse/follow", %{
          "address" => "@them@social.example"
        })

      assert redirected_to(conn) =~ "https://social.example/authorize_interaction"
    end

    test "explains a typo instead of guessing", %{conn: conn} do
      user = federating_member()
      stub_remote(fn _conn -> raise "must not be called" end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "not an address"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "@you@example.social"
    end

    test "names the server that could not be reached", %{conn: conn} do
      user = federating_member()
      stub_remote(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "social.example"
    end

    test "refuses a member who does not federate", %{conn: conn} do
      user = insert_activated_user()
      stub_remote(fn _conn -> raise "must not be called" end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not on the Fediverse"
    end

    test "refuses a member who moved their account away", %{conn: conn} do
      user = federating_member(moved_to: "https://social.example/users/greta")
      stub_remote(fn _conn -> raise "must not be called" end)

      conn = post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@them@social.example"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
    end
  end

  describe "POST /:slug/fediverse/follow with an address on this very vutuv" do
    # Whatever happens next, vutuv must not WebFinger itself over it
    # (issue #1211's shape); the stub proves no request leaves.
    setup %{conn: conn} do
      stub_remote(fn _conn -> raise "vutuv must not WebFinger itself" end)
      with_endpoint_host("vutuv.test")
      %{conn: conn}
    end

    test "a signed-in member follows the profile owner on vutuv instead", %{conn: conn} do
      user = federating_member()
      {conn, viewer} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/#{user}/fediverse/follow", %{
          "address" => "@#{viewer.username}@vutuv.test"
        })

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Social.user_follows_user?(viewer.id, user.id)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "@#{user.username}"
    end

    test "the German member reads the German confirmation", %{conn: conn} do
      user = federating_member()
      {conn, viewer} = create_and_login_user(conn)

      conn =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> post(~p"/#{user}/fediverse/follow", %{
          "address" => "@#{viewer.username}@vutuv.test"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Sie folgen"
      assert Social.user_follows_user?(viewer.id, user.id)
    end

    test "a member already following is told so, and not followed twice", %{conn: conn} do
      user = federating_member()
      {conn, viewer} = create_and_login_user(conn)
      {:ok, _} = Social.follow(viewer, user.id)

      conn =
        post(conn, ~p"/#{user}/fediverse/follow", %{
          "address" => "@#{viewer.username}@vutuv.test"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "already follow"
      assert Repo.aggregate(Social.Follow, :count) == 1
    end

    test "the owner cannot follow themselves", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})

      conn =
        post(conn, ~p"/#{user}/fediverse/follow", %{
          "address" => "@#{user.username}@vutuv.test"
        })

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "yourself"
      assert Repo.aggregate(Social.Follow, :count) == 0
    end

    test "a signed-out visitor is pointed at the Follow button, nothing happens", %{conn: conn} do
      user = federating_member()

      conn =
        post(conn, ~p"/#{user}/fediverse/follow", %{"address" => "@whoever@vutuv.test"})

      assert redirected_to(conn) == "/#{user.username}#profile-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in"
      assert Repo.aggregate(Social.Follow, :count) == 0
    end
  end
end
