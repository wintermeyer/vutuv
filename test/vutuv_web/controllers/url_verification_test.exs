defmodule VutuvWeb.UrlVerificationTest do
  @moduledoc """
  The owner-only link-verification pages (/settings/links/:id/verify) and the
  verified mark on the public link pages. `async: false` because the tests flip
  the global `:verify_user_links` flag and inject a `Req` adapter.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.Factory

  alias Vutuv.Profiles.Url
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_user_links, true)
    on_exit(fn -> Application.put_env(:vutuv, :verify_user_links, false) end)
    :ok
  end

  defp stub_body(body) do
    Application.put_env(:vutuv, :user_links_req_options,
      adapter: fn req -> {req, %Req.Response{status: 200, body: body}} end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :user_links_req_options) end)
  end

  describe "GET /settings/links/:id/verify" do
    test "renders the three methods, mints a token, and posts to the verify action", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user, value: "https://alice.example/")

      html = conn |> get(~p"/settings/links/#{url}/verify") |> html_response(200)

      # The form the buttons actually submit through — the route that exists.
      assert html =~ ~s(action="#{~p"/settings/links/#{url}/verify"}")
      assert html =~ ~s(id="verify-rel_me")
      assert html =~ ~s(id="verify-dns")
      assert html =~ ~s(id="verify-well_known")

      # The rel=me snippet points back at this member's own profile.
      assert html =~ "rel=&quot;me&quot;"
      assert html =~ "#{VutuvWeb.Endpoint.url()}/#{user.username}"

      # The DNS instructions name the host and the CNAME-safe alternate name, so
      # a member whose host is a CNAME knows where to publish the record (#947).
      assert html =~ "alice.example"
      assert html =~ "_vutuv.alice.example"

      # A token was minted for the DNS / well-known instructions.
      assert Repo.get!(Url, url.id).verification_token
    end
  end

  describe "POST /settings/links/:id/verify" do
    test "verifies via rel=me and stamps the mark", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user, value: "https://alice.example/")
      stub_body(~s(<a rel="me" href="#{VutuvWeb.Endpoint.url()}/#{user.username}">me</a>))

      conn = post(conn, ~p"/settings/links/#{url}/verify", %{"method" => "rel_me"})

      assert redirected_to(conn) == ~p"/settings/links"
      assert Repo.get!(Url, url.id).verified_at
    end

    test "redirects back with an error when the proof is missing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user, value: "https://alice.example/")
      stub_body("<p>nothing here</p>")

      conn = post(conn, ~p"/settings/links/#{url}/verify", %{"method" => "rel_me"})

      assert redirected_to(conn) == ~p"/settings/links/#{url}/verify"
      refute Repo.get!(Url, url.id).verified_at
    end

    test "cannot verify another member's link", %{conn: conn} do
      {conn, _owner} = create_and_login_user(conn)
      stranger = insert(:activated_user)
      url = insert(:url, user: stranger, value: "https://alice.example/")
      stub_body(~s(<a rel="me" href="#{VutuvWeb.Endpoint.url()}/#{stranger.username}">me</a>))

      assert_error_sent(:not_found, fn ->
        post(conn, ~p"/settings/links/#{url}/verify", %{"method" => "rel_me"})
      end)
    end
  end

  describe "verified mark on public pages" do
    test "a verified link shows the mark; an unverified one does not", %{conn: conn} do
      {_conn, user} = create_and_login_user(conn)

      insert(:url,
        user: user,
        value: "http://verified.example",
        description: "Verified site",
        verified_at: ~N[2026-07-01 12:00:00]
      )

      insert(:url, user: user, value: "http://plain.example", description: "Plain site")

      html = build_conn() |> get(~p"/#{user}/links") |> html_response(200)

      assert html =~ "Verified webpage"
    end
  end

  describe "when verification is disabled on the installation" do
    test "the verify page shows the disabled note and the POST is refused", %{conn: conn} do
      Application.put_env(:vutuv, :verify_user_links, false)
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user, value: "https://alice.example/")

      html = conn |> get(~p"/settings/links/#{url}/verify") |> html_response(200)
      assert html =~ "disabled on this installation"

      conn = post(conn, ~p"/settings/links/#{url}/verify", %{"method" => "rel_me"})
      assert redirected_to(conn) == ~p"/settings/links/#{url}/verify"
      refute Repo.get!(Url, url.id).verified_at
    end
  end
end
