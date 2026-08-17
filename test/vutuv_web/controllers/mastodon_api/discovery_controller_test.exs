defmodule VutuvWeb.MastodonApi.DiscoveryControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Posts.Post

  @mastodon_host "mastodon.localhost"

  defp on_mastodon_host(conn), do: %{conn | host: @mastodon_host}

  describe "the Mastodon API host" do
    test "serves current and legacy instance metadata", %{conn: conn} do
      v2 = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)

      assert v2["domain"] == "localhost"
      assert String.starts_with?(v2["version"], "4.4.0")

      assert v2["registrations"] == %{
               "enabled" => false,
               "approval_required" => false,
               "message" => nil
             }

      assert v2["configuration"]["statuses"]["max_characters"] ==
               Post.max_body_length()

      v1 = build_conn() |> on_mastodon_host() |> get("/api/v1/instance") |> json_response(200)

      assert v1["uri"] == "localhost"
      assert v1["version"] == v2["version"]
      assert v1["registrations"] == false
      assert v1["max_toot_chars"] == Post.max_body_length()
    end

    test "advertises the split OAuth endpoints", %{conn: conn} do
      metadata =
        conn
        |> on_mastodon_host()
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert metadata["issuer"] == "http://mastodon.localhost:4001/"
      assert metadata["authorization_endpoint"] == "http://localhost:4001/oauth/authorize"
      assert metadata["token_endpoint"] == "http://mastodon.localhost:4001/oauth/token"

      assert metadata["app_registration_endpoint"] ==
               "http://mastodon.localhost:4001/api/v1/apps"

      assert metadata["code_challenge_methods_supported"] == ["S256"]
      assert "read" in metadata["scopes_supported"]
      assert "write:statuses" in metadata["scopes_supported"]
    end

    test "redirects a legacy authorize URL to the main origin", %{conn: conn} do
      query = URI.encode_query(%{"client_id" => "client", "state" => "state"})

      conn = conn |> on_mastodon_host() |> get("/oauth/authorize?" <> query)

      assert redirected_to(conn) == "http://localhost:4001/oauth/authorize?" <> query
    end

    test "does not expose the compatibility API on the main host", %{conn: conn} do
      assert conn |> get("/api/v2/instance") |> response(404)
    end

    test "rejects another installation behind the mastodon prefix", %{conn: conn} do
      assert %{conn | host: "mastodon.example.org"}
             |> get("/api/v2/instance")
             |> response(404)
    end

    test "does not expose the website through the API origin", %{conn: conn} do
      assert conn |> on_mastodon_host() |> get("/") |> response(404)
    end

    test "returns 404 when the installation switch is off", %{conn: conn} do
      previous = Application.fetch_env!(:vutuv, :mastodon_api_enabled)
      Application.put_env(:vutuv, :mastodon_api_enabled, false)
      on_exit(fn -> Application.put_env(:vutuv, :mastodon_api_enabled, previous) end)

      assert conn |> on_mastodon_host() |> get("/api/v2/instance") |> response(404)
    end
  end

  describe "both hosts serve the client API" do
    # A member types the address they know. The subdomain stays canonical, but
    # `vutuv.de` has to work as a login or nobody finds the adapter at all.
    test "discovery answers on the main host too", %{conn: conn} do
      for path <- [
            "/api/v1/instance",
            "/api/v2/instance",
            "/.well-known/oauth-authorization-server"
          ] do
        assert conn |> Map.put(:host, "localhost") |> get(path) |> response(200)
      end
    end

    # A redirect across hosts is what this replaced: HTTP libraries drop the
    # Authorization header on one, so the login would land and every call after
    # it would 401. The endpoints therefore name the host the client arrived on.
    test "the advertised endpoints stay on the host the client used", %{conn: conn} do
      main =
        conn
        |> Map.put(:host, "localhost")
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      api =
        build_conn()
        |> Map.put(:host, "mastodon.localhost")
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert main["token_endpoint"] =~ "//localhost"
      refute main["token_endpoint"] =~ "mastodon."
      assert api["token_endpoint"] =~ "//mastodon.localhost"

      # The consent screen is a browser page and lives on the main host
      # whichever origin the client came from.
      assert main["authorization_endpoint"] == api["authorization_endpoint"]
    end

    test "an authenticated endpoint works on the main host", %{conn: conn} do
      user = insert(:activated_user)
      plaintext = "vutuv_at_" <> Vutuv.ApiAuth.random_token()
      app = insert(:oauth_app, user: nil, protocol: "mastodon", registered_scopes: ["read"])

      insert(:api_token,
        user: user,
        app: app,
        kind: "access",
        name: nil,
        scopes: ["read"],
        expires_at: nil,
        token_hash: Vutuv.ApiAuth.hash_token(plaintext)
      )

      account =
        conn
        |> Map.put(:host, "localhost")
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert account["id"] == user.id
    end

    # The first write a client makes. Everything the onboarding needs has to be
    # reachable on the typed host, or the app gives up before consent.
    test "an app can be registered on the main host", %{conn: conn} do
      credentials =
        conn
        |> Map.put(:host, "localhost")
        |> post("/api/v1/apps", %{
          "client_name" => "Hauptost-Client",
          "redirect_uris" => "https://client.example/callback",
          "scopes" => "read write"
        })
        |> json_response(200)

      assert is_binary(credentials["client_id"])
      assert is_binary(credentials["client_secret"])
    end

    # The catch-all is not mirrored: on the main host it would swallow the
    # website, so an unmatched API path falls through to the normal 404 and the
    # site keeps working.
    test "the website is untouched on the main host", %{conn: conn} do
      assert conn |> Map.put(:host, "localhost") |> get("/") |> response(200)

      assert build_conn()
             |> Map.put(:host, "localhost")
             |> get("/api/v1/definitely-not-a-route")
             |> response(404)
    end
  end
end
