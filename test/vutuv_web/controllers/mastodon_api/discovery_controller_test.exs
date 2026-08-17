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
end
