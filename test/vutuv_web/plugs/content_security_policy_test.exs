defmodule VutuvWeb.Plug.ContentSecurityPolicyTest do
  @moduledoc """
  Every browser-pipeline response carries a Content-Security-Policy. With
  user-supplied Markdown rendered all over the site, CSP is the second line
  of defense should an XSS slip past the sanitizer: no external or inline
  scripts can run, forms cannot be re-targeted off-site.
  """
  use VutuvWeb.ConnCase

  defp csp(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [value] -> value
      [] -> nil
    end
  end

  test "pages carry the policy: self-only scripts, no objects", %{conn: conn} do
    policy = conn |> get(~p"/") |> csp()

    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "base-uri 'self'"
    assert policy =~ "form-action 'self'"
    # The CSS data-URI icons in components.css load as images.
    assert policy =~ "img-src 'self' data:"
  end

  test "connect-src names the websocket origin so LiveView can join", %{conn: conn} do
    policy = conn |> get(~p"/") |> csp()

    # ConnTest conns are http://www.example.com → ws://www.example.com.
    assert policy =~ "connect-src 'self' ws://www.example.com"
  end

  test "the unsubscribe pipeline carries it too", %{conn: conn} do
    user = insert(:activated_user)
    token = VutuvWeb.UnsubscribeToken.sign(user)

    policy = conn |> get(~p"/unsubscribe/#{token}") |> csp()
    assert policy =~ "default-src 'self'"
  end

  # `form-action` is enforced on every hop of a submission, redirects included,
  # and POST /oauth/authorize answers 302 to the client's callback. Under a bare
  # `form-action 'self'` the browser blocks that hop: the POST lands, a code is
  # minted, and the member is left on the consent screen with no token and no
  # error — the Ivory report ("nothing happens when I tap Allow"). Reverting
  # VutuvWeb.Plug.ContentSecurityPolicy.allow_form_action/2 must turn these red.
  defp consent_policy(conn, redirect_uri) do
    {:ok, app, _secret} =
      Vutuv.ApiAuth.create_mastodon_app(%{
        "name" => "Phone Client",
        "redirect_uris" => [redirect_uri],
        "registered_scopes" => ["read"]
      })

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => redirect_uri,
        "scope" => "read"
      })

    conn = get(conn, "/oauth/authorize?#{query}")
    assert html_response(conn, 200) =~ "Phone Client"
    csp(conn)
  end

  describe "form-action on the OAuth consent screen" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "a native client's scheme is allowed, so the ivory:// hop is not blocked",
         %{conn: conn} do
      assert consent_policy(conn, "ivory://oauth-callback") =~ "form-action 'self' ivory:;"
    end

    test "an https callback is allowed by exact origin, not by wildcard", %{conn: conn} do
      policy = consent_policy(conn, "https://client.example.org/cb")

      assert policy =~ "form-action 'self' https://client.example.org;"
      refute policy =~ "form-action 'self' *"
    end

    test "the approve response carries it too", %{conn: conn, user: user} do
      # Consent for a Mastodon client needs the member's own kill switch on.
      user |> Ecto.Changeset.change(%{mastodon_clients?: true}) |> Repo.update!()

      {:ok, app, _secret} =
        Vutuv.ApiAuth.create_mastodon_app(%{
          "name" => "Phone Client",
          "redirect_uris" => ["ivory://oauth-callback"],
          "registered_scopes" => ["read"]
        })

      params = %{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => "ivory://oauth-callback",
        "scope" => "read"
      }

      conn = get(conn, "/oauth/authorize?#{URI.encode_query(params)}")
      conn = submit_with_csrf(conn, "/oauth/authorize", Map.put(params, "decision", "allow"))

      assert redirected_to(conn) =~ "ivory://oauth-callback?code="
      assert csp(conn) =~ "form-action 'self' ivory:;"
    end

    test "every other page keeps the bare directive", %{conn: conn} do
      assert csp(get(conn, ~p"/")) =~ "form-action 'self';"
    end

    test "a registered URI that would splice a second directive widens nothing",
         %{conn: conn} do
      # App registration is public and `URI.parse/1` validates nothing, so
      # everything up to the first "/" comes back as the "host".
      policy = consent_policy(conn, "https://evil.example.org;script-src 'unsafe-inline'/cb")

      assert policy =~ "form-action 'self';"
      refute policy =~ "unsafe-inline'/cb"
    end

    test "the out-of-band flow stays strict, because it never redirects", %{conn: conn} do
      assert consent_policy(conn, "urn:ietf:wg:oauth:2.0:oob") =~ "form-action 'self';"
    end
  end

  describe "form_action_source/1" do
    alias VutuvWeb.Plug.ContentSecurityPolicy

    test "http(s) gets an origin, a default port is left off" do
      assert ContentSecurityPolicy.form_action_source("https://a.example/cb") ==
               "https://a.example"

      assert ContentSecurityPolicy.form_action_source("http://localhost:4000/cb") ==
               "http://localhost:4000"
    end

    test "a native scheme gets the scheme, whatever shape the rest has" do
      assert ContentSecurityPolicy.form_action_source("ivory://oauth-callback") == "ivory:"
      assert ContentSecurityPolicy.form_action_source("com.example.app:/cb") == "com.example.app:"
    end

    test "nothing usable yields nil, so the policy is left alone" do
      assert ContentSecurityPolicy.form_action_source("/relative") == nil
      assert ContentSecurityPolicy.form_action_source(nil) == nil
    end

    test "a host CSP cannot spell yields nil rather than a header we did not write" do
      assert ContentSecurityPolicy.form_action_source("https://a.example;script-src 'x'/cb") ==
               nil

      assert ContentSecurityPolicy.form_action_source("https://intra_net.example/cb") == nil
      assert ContentSecurityPolicy.form_action_source("urn:ietf:wg:oauth:2.0:oob") == nil
    end
  end

  test "the strict default never allows eval (the dev escape hatch is off here)",
       %{conn: conn} do
    # `script-src 'self' 'unsafe-eval'` is added only when
    # `config :vutuv, csp: [allow_eval: true]` (dev.exs, so the Tidewave
    # browser_eval tool can run). Test and prod builds never load that config, so
    # they must carry neither the directive nor `unsafe-eval` — eval is an XSS
    # amplifier. See VutuvWeb.Plug.ContentSecurityPolicy.
    policy = conn |> get(~p"/") |> csp()

    refute policy =~ "unsafe-eval"
    refute policy =~ "script-src"
  end
end
