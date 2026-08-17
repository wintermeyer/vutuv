defmodule VutuvWeb.MastodonApi.OauthControllerTest do
  use VutuvWeb.ConnCase

  import Vutuv.OrganizationsHelpers

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.App
  alias Vutuv.Organizations
  alias Vutuv.Repo

  @mastodon_host "mastodon.localhost"
  @redirect "org.example.client://oauth"

  setup do
    Vutuv.RateLimiter.reset()
    original_verification = Application.fetch_env(:vutuv, :verify_organization_domains)
    original_resolver = Application.fetch_env(:vutuv, :organizations_dns_resolver)
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      case original_verification do
        {:ok, value} -> Application.put_env(:vutuv, :verify_organization_domains, value)
        :error -> Application.delete_env(:vutuv, :verify_organization_domains)
      end

      case original_resolver do
        {:ok, value} -> Application.put_env(:vutuv, :organizations_dns_resolver, value)
        :error -> Application.delete_env(:vutuv, :organizations_dns_resolver)
      end
    end)

    :ok
  end

  defp on_mastodon_host(conn), do: %{conn | host: @mastodon_host}
  defp fresh_conn, do: build_conn() |> init_test_session(%{})

  defp registration_params do
    %{
      "client_name" => "Pocket Client",
      "redirect_uris" => [@redirect],
      "scopes" => "read write:statuses",
      "website" => "https://client.example.org"
    }
  end

  defp register(conn, overrides \\ %{}) do
    conn
    |> on_mastodon_host()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/apps", Jason.encode!(Map.merge(registration_params(), overrides)))
  end

  describe "POST /api/v1/apps" do
    test "registers an unattended confidential Mastodon client", %{conn: conn} do
      response = conn |> register() |> json_response(200)

      assert response["name"] == "Pocket Client"
      assert response["website"] == "https://client.example.org"
      assert response["scopes"] == ["read", "write:statuses"]
      assert response["redirect_uri"] == @redirect
      assert response["redirect_uris"] == [@redirect]
      assert response["client_id"] =~ "vutuv_app_"
      assert response["client_secret"] =~ "vutuv_sec_"
      assert response["client_secret_expires_at"] == 0

      app = Repo.get_by!(App, client_id: response["client_id"])
      assert app.protocol == "mastodon"
      assert app.registered_scopes == ["read", "write:statuses"]
      assert is_nil(app.user_id)
      refute app.client_secret_hash == response["client_secret"]
    end

    test "accepts the legacy newline-separated redirect field", %{conn: conn} do
      response =
        conn
        |> register(%{"redirect_uris" => @redirect <> "\nhttps://client.example.org/oauth"})
        |> json_response(200)

      assert response["redirect_uris"] == [@redirect, "https://client.example.org/oauth"]
      assert response["redirect_uri"] == @redirect <> "\nhttps://client.example.org/oauth"
    end

    test "accepts granular relationship and engagement scopes", %{conn: conn} do
      scopes =
        "read:search read:follows write:follows write:mutes write:blocks " <>
          "write:favourites write:bookmarks"

      response = conn |> register(%{"scopes" => scopes}) |> json_response(200)

      assert response["scopes"] == String.split(scopes)
    end

    test "rejects unknown scopes and unsafe redirect schemes", %{conn: conn} do
      assert %{"error" => _message} =
               conn
               |> register(%{"scopes" => "admin:write"})
               |> json_response(422)

      assert %{"error" => _message} =
               build_conn()
               |> register(%{"redirect_uris" => ["javascript:alert(1)"]})
               |> json_response(422)
    end
  end

  describe "Mastodon authorization-code flow" do
    # A page acts with the Redaktion's powers, so `read write follow` all
    # survive — but `write:blocks` never does, whatever the client asks for and
    # whatever roles the member holds: a block is between two people and a page
    # is not one. The token is minted with the narrowed set rather than the
    # requested one, so the reduction is durable instead of a per-request veto.
    test "selects an organization identity and narrows its scopes to live roles", %{conn: conn} do
      credentials =
        conn
        |> register(%{"scopes" => "read write follow write:blocks"})
        |> json_response(200)

      {conn, user} = create_and_login_user(fresh_conn())
      target = insert(:activated_user)
      organization = active_organization_for(user)
      {:ok, _} = Organizations.add_role(organization, user, "publisher", user)

      authorize_params = %{
        "response_type" => "code",
        "client_id" => credentials["client_id"],
        "redirect_uri" => @redirect,
        "scope" => "read write follow write:blocks"
      }

      conn = get(conn, "/oauth/authorize?#{URI.encode_query(authorize_params)}")
      assert html_response(conn, 200) =~ organization.name

      conn =
        submit_with_csrf(
          conn,
          "/oauth/authorize",
          authorize_params
          |> Map.put("decision", "allow")
          |> Map.put("identity", "organization:" <> organization.id)
        )

      %{query: query} = URI.parse(redirected_to(conn))
      %{"code" => code} = URI.decode_query(query)

      token =
        build_conn()
        |> on_mastodon_host()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => credentials["client_id"],
          "client_secret" => credentials["client_secret"],
          "redirect_uri" => @redirect,
          "code" => code
        })
        |> json_response(200)

      assert token["scope"] == "read write follow"

      account =
        build_conn()
        |> on_mastodon_host()
        |> put_req_header("authorization", "Bearer " <> token["access_token"])
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert account["id"] == organization.id
      assert account["display_name"] == organization.name

      assert build_conn()
             |> on_mastodon_host()
             |> put_req_header("authorization", "Bearer " <> token["access_token"])
             |> post("/api/v1/accounts/#{target.id}/follow")
             |> response(200)

      assert build_conn()
             |> on_mastodon_host()
             |> put_req_header("authorization", "Bearer " <> token["access_token"])
             |> post("/api/v1/accounts/#{target.id}/block")
             |> response(403)
    end

    test "logs in without legacy PKCE, returns a non-expiring token and identifies the member", %{
      conn: conn
    } do
      credentials = conn |> register() |> json_response(200)
      app = Repo.get_by!(App, client_id: credentials["client_id"])
      {conn, user} = create_and_login_user(fresh_conn())

      authorize_params = %{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => @redirect,
        "scope" => "read write:statuses",
        "state" => "mastodon-state"
      }

      conn = get(conn, "/oauth/authorize?#{URI.encode_query(authorize_params)}")
      assert html_response(conn, 200) =~ "Pocket Client"

      conn =
        submit_with_csrf(
          conn,
          "/oauth/authorize",
          Map.put(authorize_params, "decision", "allow")
        )

      %{query: query} = URI.parse(redirected_to(conn))
      %{"code" => code, "state" => "mastodon-state"} = URI.decode_query(query)

      token_response =
        build_conn()
        |> on_mastodon_host()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => credentials["client_secret"],
          "redirect_uri" => @redirect,
          "code" => code
        })
        |> json_response(200)

      assert token_response["token_type"] == "Bearer"
      assert token_response["scope"] == "read write:statuses"
      assert is_integer(token_response["created_at"])
      refute Map.has_key?(token_response, "expires_in")
      refute Map.has_key?(token_response, "refresh_token")

      account =
        build_conn()
        |> on_mastodon_host()
        |> put_req_header("authorization", "Bearer " <> token_response["access_token"])
        |> get("/api/v1/accounts/verify_credentials")
        |> json_response(200)

      assert account["id"] == user.id
      assert account["username"] == user.username
      assert account["acct"] == user.username
      assert account["url"] == "http://localhost:4001/#{user.username}"

      # Mastodon grants stay isolated from the native API vocabulary.
      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> token_response["access_token"])
             |> get("/api/2.0/me")
             |> response(403)
    end

    test "cannot authorize a scope the client did not register", %{conn: conn} do
      credentials = conn |> register(%{"scopes" => "read"}) |> json_response(200)
      {conn, _user} = create_and_login_user(fresh_conn())

      conn =
        get(
          conn,
          "/oauth/authorize?" <>
            URI.encode_query(%{
              "response_type" => "code",
              "client_id" => credentials["client_id"],
              "redirect_uri" => @redirect,
              "scope" => "write:statuses"
            })
        )

      assert html_response(conn, 400) =~ "oauth-error"
    end

    test "shows the code for the legacy out-of-band redirect", %{conn: conn} do
      redirect = "urn:ietf:wg:oauth:2.0:oob"

      credentials =
        conn
        |> register(%{"redirect_uris" => [redirect], "scopes" => "read"})
        |> json_response(200)

      {conn, _user} = create_and_login_user(fresh_conn())

      authorize_params = %{
        "response_type" => "code",
        "client_id" => credentials["client_id"],
        "redirect_uri" => redirect,
        "scope" => "read"
      }

      conn = get(conn, "/oauth/authorize?#{URI.encode_query(authorize_params)}")

      conn =
        submit_with_csrf(
          conn,
          "/oauth/authorize",
          Map.put(authorize_params, "decision", "allow")
        )

      assert text_response(conn, 200) =~ "vutuv_ac_"
    end

    test "keeps PKCE mandatory for a native vutuv OAuth application", %{conn: conn} do
      developer = insert_activated_user()

      {:ok, app, _secret} =
        ApiAuth.create_app(developer, %{
          "name" => "Native App",
          "redirect_uris" => ["https://native.example.org/oauth"]
        })

      {conn, _user} = create_and_login_user(conn)

      conn =
        get(
          conn,
          "/oauth/authorize?" <>
            URI.encode_query(%{
              "response_type" => "code",
              "client_id" => app.client_id,
              "redirect_uri" => "https://native.example.org/oauth",
              "scope" => "profile:read"
            })
        )

      assert html_response(conn, 400) =~ "oauth-error"
    end
  end
end
