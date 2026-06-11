defmodule VutuvWeb.OauthControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth

  @redirect "https://app.example.org/callback"

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    developer = insert_activated_user()

    {:ok, app, secret} =
      ApiAuth.create_app(developer, %{"name" => "Calendar Sync", "redirect_uris" => [@redirect]})

    {:ok, conn: conn, developer: developer, app: app, secret: secret}
  end

  defp verifier, do: String.duplicate("v", 50)
  defp challenge, do: Base.url_encode64(:crypto.hash(:sha256, verifier()), padding: false)

  defp authorize_query(app, overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => @redirect,
        "scope" => "profile:read",
        "state" => "st4te",
        "code_challenge" => challenge(),
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end

  describe "GET /oauth/authorize" do
    test "logged out: stores the return path and sends to login", %{conn: conn, app: app} do
      conn = get(conn, "/oauth/authorize?#{URI.encode_query(authorize_query(app))}")

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :login_return_to) =~ "/oauth/authorize?"
    end

    test "after the PIN login the visitor lands back on the consent screen", %{
      conn: conn,
      app: app
    } do
      path = "/oauth/authorize?#{URI.encode_query(authorize_query(app))}"
      conn = get(conn, path)

      {:ok, _user} =
        Vutuv.Accounts.register_user(conn, %{
          "emails" => %{"0" => %{"value" => "consent@example.com"}},
          "first_name" => "Consent"
        })

      # Drive the real two-step PIN login over HTTP; ConnTest recycles the
      # cookies, so the stored return path rides along in the session.
      conn = post(conn, ~p"/login", session: %{"email" => "consent@example.com"})
      conn = post(conn, ~p"/login", session: %{"pin" => sent_pin()})

      assert redirected_to(conn) == path
    end

    test "logged in: renders the consent screen with the scopes", %{conn: conn, app: app} do
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, "/oauth/authorize?#{URI.encode_query(authorize_query(app))}")
      response = html_response(conn, 200)

      assert response =~ "Calendar Sync"
      assert response =~ "profile:read"
      assert response =~ "oauth-allow"
    end

    test "a foreign redirect_uri renders an error page, never a redirect", %{
      conn: conn,
      app: app
    } do
      {conn, _user} = create_and_login_user(conn)

      query = authorize_query(app, %{"redirect_uri" => "https://evil.example.org/cb"})
      conn = get(conn, "/oauth/authorize?#{URI.encode_query(query)}")

      assert conn.status == 400
      assert conn.resp_body =~ "oauth-error"
    end
  end

  describe "the full flow over HTTP" do
    test "consent → code → token → API call → refresh → revoke", %{
      conn: conn,
      app: app,
      secret: secret
    } do
      {conn, user} = create_and_login_user(conn)

      # Approve (CSRF-protected browser form, like a real submit).
      conn = get(conn, "/oauth/authorize?#{URI.encode_query(authorize_query(app))}")

      conn =
        submit_with_csrf(
          conn,
          "/oauth/authorize",
          Map.put(authorize_query(app), "decision", "allow")
        )

      location = redirected_to(conn)
      assert location =~ @redirect <> "?"
      %{query: query} = URI.parse(location)
      %{"code" => code, "state" => "st4te"} = URI.decode_query(query)

      # Exchange the code (machine endpoint, form-encoded).
      conn =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier()
        })

      tokens = json_response(conn, 200)

      assert %{"access_token" => access, "refresh_token" => refresh, "token_type" => "Bearer"} =
               tokens

      # The access token works against the API, as the consenting user.
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> access)
        |> get("/api/v1/me")

      assert json_response(conn, 200)["slug"] == user.active_slug

      # Refresh rotates the pair.
      conn =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "client_id" => app.client_id,
          "client_secret" => secret,
          "refresh_token" => refresh
        })

      assert %{"access_token" => access2} = json_response(conn, 200)
      assert access2 != access

      # RFC 7009 revocation kills the new pair.
      conn =
        build_conn()
        |> post("/oauth/revoke", %{
          "client_id" => app.client_id,
          "client_secret" => secret,
          "token" => access2
        })

      assert conn.status == 200

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> access2)
        |> get("/api/v1/me")

      assert conn.status == 401
    end

    test "deny bounces back with access_denied and no grant", %{conn: conn, app: app} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, "/oauth/authorize?#{URI.encode_query(authorize_query(app))}")

      conn =
        submit_with_csrf(
          conn,
          "/oauth/authorize",
          Map.put(authorize_query(app), "decision", "deny")
        )

      location = redirected_to(conn)
      assert location =~ "error=access_denied"
      assert location =~ "state=st4te"
      assert ApiAuth.list_grants(user) == []
    end

    test "wrong client credentials at the token endpoint are a 401", %{conn: conn, app: app} do
      conn =
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => "vutuv_sec_wrong",
          "code" => "whatever",
          "redirect_uri" => @redirect,
          "code_verifier" => verifier()
        })

      assert json_response(conn, 401)["error"] == "invalid_client"
    end
  end

  describe "connected apps page" do
    test "lists the grant and revokes it", %{conn: conn, app: app, secret: secret} do
      {conn, user} = create_and_login_user(conn)

      # Grant via the context (the HTTP flow is covered above).
      {:ok, request} =
        Vutuv.ApiAuth.OAuth.validate_authorize(authorize_query(app))

      {:ok, code} = Vutuv.ApiAuth.OAuth.approve(user, request)

      {:ok, tokens} =
        Vutuv.ApiAuth.OAuth.exchange(%{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier()
        })

      response = conn |> get(~p"/connected_apps") |> html_response(200)
      assert response =~ "Calendar Sync"

      [grant] = ApiAuth.list_grants(user)
      conn = delete(conn, ~p"/connected_apps/#{grant.id}")
      assert redirected_to(conn) == ~p"/connected_apps"
      assert {:error, :revoked} = ApiAuth.verify_token(tokens.access_token)
    end
  end

  describe "developer app registry" do
    test "register, see the secret once, regenerate, delete", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/developers/apps",
          app: %{
            "name" => "My Tool",
            "redirect_uris_text" => "https://tool.example.org/cb\n"
          }
        )

      assert "/developers/apps/" <> id = redirected_to(conn)

      conn = get(conn, ~p"/developers/apps/#{id}")
      response = html_response(conn, 200)
      assert [_, secret] = Regex.run(~r/(vutuv_sec_[a-z2-7]+)/, response)

      # Shown once: a reload no longer carries it.
      refute conn |> get(~p"/developers/apps/#{id}") |> html_response(200) =~ secret

      conn = post(conn, ~p"/developers/apps/#{id}/regenerate_secret")
      assert redirected_to(conn) == "/developers/apps/#{id}"

      conn = delete(conn, ~p"/developers/apps/#{id}")
      assert redirected_to(conn) == ~p"/developers/apps"
    end

    test "the registry is per owner", %{conn: conn, app: app} do
      {conn, _user} = create_and_login_user(conn)

      refute conn |> get(~p"/developers/apps") |> html_response(200) =~ app.name
      assert get(conn, ~p"/developers/apps/#{app.id}").status == 404
    end
  end

  describe "admin kill switch" do
    test "suspend refuses the app's tokens, reactivate restores them", %{
      conn: conn,
      app: app,
      secret: secret
    } do
      member = insert_activated_user()

      {:ok, request} = Vutuv.ApiAuth.OAuth.validate_authorize(authorize_query(app))
      {:ok, code} = Vutuv.ApiAuth.OAuth.approve(member, request)

      {:ok, tokens} =
        Vutuv.ApiAuth.OAuth.exchange(%{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier()
        })

      {conn, _admin} = create_and_login_admin(conn)

      assert conn |> get(~p"/admin/api_apps") |> html_response(200) =~ "Calendar Sync"

      conn = post(conn, ~p"/admin/api_apps/#{app.id}/suspend")
      assert redirected_to(conn) == ~p"/admin/api_apps"
      assert {:error, :app_suspended} = ApiAuth.verify_token(tokens.access_token)

      post(conn, ~p"/admin/api_apps/#{app.id}/unsuspend")
      assert {:ok, _token, _user} = ApiAuth.verify_token(tokens.access_token)
    end
  end
end
