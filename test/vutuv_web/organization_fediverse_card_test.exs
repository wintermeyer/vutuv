defmodule VutuvWeb.OrganizationFediverseCardTest do
  @moduledoc """
  The organization page's Fediverse card and its "Follow from your own server"
  button (issue #1334): what a visitor arriving from Mastodon sees on a page, and
  what happens when they hand us their own address.

  The page had a Fediverse address, answered WebFinger under it and served an
  actor document — and showed it on no page a human reads, which is what was
  reported. The member profile's equivalent is
  `VutuvWeb.UserProfileFediverseTest`; both surfaces render one component and
  post to one controller, so these two files describe the same act from the two
  ends it can be met at.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag, and the installation switch and the HTTP
  stub for the remote WebFinger lookup both live in the application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.EndpointHostHelper
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Repo
  alias Vutuv.Social
  alias VutuvWeb.Fediverse.Docs

  @card "#organization-fediverse"
  @handle "#organization-fediverse-handle"
  @form "#remote-follow-form"
  @shortcut "#organization-fediverse-shortcut"
  @invite "#organization-fediverse-enable"

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp federating_page(attrs \\ %{}) do
    active_organization_for(insert(:activated_user))
    |> Ecto.Changeset.change(Map.merge(%{fediverse_followers?: true, username: "acme"}, attrs))
    |> Repo.update!()
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
    test "shows a federating page's handle to a logged-out visitor", %{conn: conn} do
      page = federating_page()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      assert has_element?(view, @card)
      assert render(view) =~ Docs.handle(page)
      assert has_element?(view, @form)
    end

    test "is absent for a page that does not federate", %{conn: conn} do
      page = active_organization_for(insert(:activated_user))

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      refute has_element?(view, @card)
      refute has_element?(view, @shortcut)
    end

    test "invites the owner of a page that does not federate, and nobody else", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      page = active_organization_for(owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      # The whole feature was unreachable: the switch lives behind the manage
      # tab bar, which only renders on the manage pages themselves, and the
      # page's own owner row named Edit / Team / Domains and nothing else. An
      # owner had to click "Edit" and notice a tab to learn that their page can
      # federate at all. So the empty section teaches it, the way every other
      # empty section on this app teaches what goes in it.
      assert has_element?(view, "#{@card} [data-empty-add]")
      assert has_element?(view, @invite)
      assert view |> element(@invite) |> render() =~ "/organizations/#{page.slug}/fediverse"

      # And it is scaffolding for the owner, not something a visitor reads.
      {:ok, visitor, _html} = live(build_conn(), ~p"/organizations/#{page.slug}")
      refute has_element?(visitor, @card)
    end

    test "no invitation while the installation switch is off", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      page = active_organization_for(owner)
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      # There is nothing to switch on: this installation exchanges nothing with
      # other networks, and the switch page itself says so.
      refute has_element?(view, @card)
    end

    test "the owner row on the page names the Fediverse", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      page = active_organization_for(owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      # The row beside Edit / Team / Domains, so the switch is reachable from
      # the top of the page too, not only from the card at its foot.
      assert has_element?(view, ~s|#organization-manage-fediverse|)
    end

    test "the owner row keeps the Fediverse to the owner", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      page = active_organization_for(insert(:activated_user))

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      refute has_element?(view, ~s|#organization-manage-fediverse|)
    end

    test "is absent for a page that never claimed a handle", %{conn: conn} do
      # The handle IS the address out there, so opting in without one leaves
      # nothing to show — the same gate the actor endpoints answer 404 on.
      page = federating_page(%{username: nil})

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      refute has_element?(view, @card)
    end

    test "is absent while the installation switch is off", %{conn: conn} do
      page = federating_page()
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      refute has_element?(view, @card)
    end

    test "the form posts to the route that exists", %{conn: conn} do
      page = federating_page()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      # Not the route the writer remembered: a hand-built path in a test would
      # have passed while every Save button on /settings 404ed in production
      # (v7.34 to v7.42), which is why this asserts the rendered action.
      assert view |> element(@form) |> render() =~
               ~s|action="/organizations/#{page.slug}/fediverse/follow"|
    end
  end

  describe "the shortcut in the page header" do
    test "names the address and points at the card", %{conn: conn} do
      page = federating_page()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      assert view |> element(@shortcut) |> render() =~ Docs.handle(page)
      assert view |> element(@shortcut) |> render() =~ ~s|href="#organization-fediverse"|
    end

    test "does not repeat the card's tools", %{conn: conn} do
      page = federating_page()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

      # The explanation, the copy button and the follow form exist once, at the
      # foot of the page; the shortcut is the way to them, not a second copy.
      refute has_element?(view, "#{@shortcut} [data-copy]")
      refute has_element?(view, "#{@shortcut} #{@handle}")
    end
  end

  describe "POST /organizations/:slug/fediverse/follow" do
    test "sends the visitor to their own server's follow dialog", %{conn: conn} do
      page = federating_page()
      serve_subscribe_template()

      conn =
        post(conn, ~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "@them@social.example"
        })

      assert redirected_to(conn) ==
               "https://social.example/authorize_interaction?uri=" <>
                 URI.encode_www_form("acct:" <> Docs.acct(page))
    end

    test "the token the rendered form carries really passes CSRF", %{conn: conn} do
      page = federating_page()
      serve_subscribe_template()

      # ConnTest skips CSRF on a plain post/3, so the thing worth proving is
      # that the token a LiveView-rendered form stamps is accepted: the page is
      # rendered by a LiveView, which loads the session's CSRF state separately
      # from the controller.
      conn = get(conn, ~p"/organizations/#{page.slug}")

      conn =
        submit_with_csrf(conn, ~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "@them@social.example"
        })

      assert redirected_to(conn) =~ "https://social.example/authorize_interaction"
    end

    test "explains a typo instead of guessing, back on the card", %{conn: conn} do
      page = federating_page()
      stub_remote(fn _conn -> raise "must not be called" end)

      conn =
        post(conn, ~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "not an address"
        })

      # The canonical path of a page that claimed a handle is the root one.
      assert redirected_to(conn) == "/acme#organization-fediverse"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "@you@example.social"
    end

    test "refuses a page that does not federate", %{conn: conn} do
      page = active_organization_for(insert(:activated_user))
      stub_remote(fn _conn -> raise "must not be called" end)

      conn =
        post(conn, ~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "@them@social.example"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not on the Fediverse"
    end

    test "404s for a page nobody may see", %{conn: conn} do
      page = federating_page()
      {:ok, _} = Vutuv.Organizations.admin_set_frozen(page, true)

      conn
      |> post(~p"/organizations/#{page.slug}/fediverse/follow", %{
        "address" => "@them@social.example"
      })
      |> response(404)
    end
  end

  describe "POST with an address on this very vutuv" do
    # Whatever happens next, vutuv must not WebFinger itself (issue #1211's
    # shape); the stub proves no request leaves.
    setup %{conn: conn} do
      stub_remote(fn _conn -> raise "vutuv must not WebFinger itself" end)
      with_endpoint_host("vutuv.test")
      %{conn: conn}
    end

    test "a signed-in member follows the page on vutuv instead", %{conn: conn} do
      # The viewer logs in FIRST: creating a page mails its owner, and
      # `sent_pin/0` reads the oldest email in the mailbox, so a page created
      # before the login hands the PIN reader somebody else's letter.
      {conn, viewer} = create_and_login_user(conn)
      page = federating_page()

      conn =
        post(conn, ~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "@#{viewer.username}@vutuv.test"
        })

      assert redirected_to(conn) == "/acme#organization-fediverse"
      assert Social.follows_organization?(viewer, page)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "@acme"
    end

    test "a member already following is told so, and not followed twice", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      page = federating_page()
      {:ok, _} = Social.follow_organization(viewer, page)

      conn =
        post(conn, ~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "@#{viewer.username}@vutuv.test"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "already follow"
      assert Repo.aggregate(Social.Follow, :count) == 1
    end

    test "a signed-out visitor is pointed at the Follow button, nothing happens", %{conn: conn} do
      page = federating_page()

      conn =
        post(conn, ~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "@whoever@vutuv.test"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in"
      assert Repo.aggregate(Social.Follow, :count) == 0
    end
  end

  describe "the page's other renderings" do
    test "the agent formats carry the address too", %{conn: conn} do
      page = federating_page()

      markdown = conn |> get("/organizations/#{page.slug}.md") |> response(200)
      assert markdown =~ Docs.handle(page)

      json = conn |> get("/organizations/#{page.slug}.json") |> json_response(200)
      assert json["fediverse"]["handle"] == Docs.handle(page)
      assert json["fediverse"]["actor_url"] =~ "/organizations/#{page.slug}/actor"
    end

    test "an ActivityPub Accept on the page URL gets the actor document", %{conn: conn} do
      page = federating_page()

      # What Mastodon fetches when somebody pastes the page's URL into its
      # search. Without it a pasted page URL answers with HTML, which an AP
      # client cannot read — the address on the card would be findable and the
      # URL beside it would not resolve.
      json =
        conn
        |> put_req_header("accept", "application/activity+json")
        |> get(~p"/organizations/#{page.slug}")
        |> json_response(200)

      assert json["type"] == "Organization"
      assert json["preferredUsername"] == "acme"
    end

    test "a page that does not federate refuses the ActivityPub Accept", %{conn: conn} do
      page = active_organization_for(insert(:activated_user))

      conn
      |> put_req_header("accept", "application/activity+json")
      |> get(~p"/organizations/#{page.slug}")
      |> response(404)
    end
  end

  describe "German" do
    test "the card reads as German, and about the page", %{conn: conn} do
      page = federating_page()

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/organizations/#{page.slug}")
        |> html_response(200)

      # The whole sentence, not a fragment: `mix gettext.extract --merge`
      # fuzzy-fills a new msgid from an unrelated one and flags it in a form the
      # obvious grep misses, so a German page can ship confident nonsense while
      # every English test stays green.
      assert html =~ "Sie sind auf Mastodon oder in einer anderen Fediverse-App?"
      assert html =~ "Folgen Sie #{page.name} von dort aus"
      assert html =~ "Von Ihrem eigenen Server aus folgen"
    end

    test "the owner's invitation reads as German", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      page = active_organization_for(owner)

      html =
        conn
        |> Phoenix.ConnTest.recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/organizations/#{page.slug}")
        |> html_response(200)

      # The offer leads with what it does for the organization (reach past
      # vutuv), not with the name of a protocol. "Föderieren" is the word this
      # path used to be written in and almost nobody outside the Fediverse knows
      # it, so it is named here to keep it out.
      assert html =~ "Seite für andere Netzwerke einrichten"
      assert html =~ "Auch Menschen ohne vutuv-Konto können dieser Seite folgen"
      assert html =~ "wie eine E-Mail-Adresse aussieht"
      refute html =~ "öderier"
    end

    test "the refusal for a page that does not federate is German", %{conn: conn} do
      page = active_organization_for(insert(:activated_user))
      stub_remote(fn _conn -> raise "must not be called" end)

      conn =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> post(~p"/organizations/#{page.slug}/fediverse/follow", %{
          "address" => "@them@social.example"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Fediverse"
      refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ "This page"
    end
  end
end
