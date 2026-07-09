defmodule Vutuv.ApiAuth.OAuthTest do
  use Vutuv.DataCase

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.OAuth

  @redirect "https://app.example.org/callback"

  setup do
    developer = insert_activated_user()
    member = insert_activated_user()

    {:ok, app, secret} =
      ApiAuth.create_app(developer, %{
        "name" => "Test App",
        "redirect_uris" => [@redirect]
      })

    {:ok, developer: developer, member: member, app: app, secret: secret}
  end

  defp verifier, do: String.duplicate("v", 50)
  defp challenge, do: Base.url_encode64(:crypto.hash(:sha256, verifier()), padding: false)

  defp authorize_params(app, overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => @redirect,
        "scope" => "profile:read posts:write",
        "state" => "xyz",
        "code_challenge" => challenge(),
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end

  defp run_flow(member, app, secret) do
    {:ok, request} = OAuth.validate_authorize(authorize_params(app))
    {:ok, code} = OAuth.approve(member, request)

    OAuth.exchange(%{
      "grant_type" => "authorization_code",
      "client_id" => app.client_id,
      "client_secret" => secret,
      "code" => code,
      "redirect_uri" => @redirect,
      "code_verifier" => verifier()
    })
  end

  describe "app registration" do
    test "mints prefixed credentials and stores only the secret hash", %{app: app, secret: secret} do
      assert String.starts_with?(app.client_id, "vutuv_app_")
      assert String.starts_with?(secret, "vutuv_sec_")
      refute app.client_secret_hash == secret
    end

    test "redirect URIs must be https (localhost excepted)", %{developer: developer} do
      assert {:error, changeset} =
               ApiAuth.create_app(developer, %{
                 "name" => "Bad",
                 "redirect_uris" => ["http://evil.example.org/cb"]
               })

      assert %{redirect_uris: _} = errors_on(changeset)

      assert {:ok, _app, _secret} =
               ApiAuth.create_app(developer, %{
                 "name" => "Dev",
                 "redirect_uris" => ["http://localhost:4000/cb"]
               })
    end

    test "a redirect URI longer than the varchar(255) column is rejected", %{
      developer: developer
    } do
      long = "https://example.org/" <> String.duplicate("a", 260)

      assert {:error, changeset} =
               ApiAuth.create_app(developer, %{"name" => "Long", "redirect_uris" => [long]})

      assert %{redirect_uris: _} = errors_on(changeset)
    end

    test "regenerating the secret invalidates the old one", %{
      member: member,
      app: app,
      secret: secret
    } do
      {app, new_secret} = ApiAuth.regenerate_secret!(app)

      assert {:error, :invalid_client} = run_flow(member, app, secret)
      assert {:ok, _tokens} = run_flow(member, app, new_secret)
    end
  end

  describe "validate_authorize/1" do
    test "accepts a complete request", %{app: app} do
      assert {:ok, %{app: %{id: id}, scopes: ["profile:read", "posts:write"], state: "xyz"}} =
               OAuth.validate_authorize(authorize_params(app))

      assert id == app.id
    end

    test "rejects unknown clients, foreign redirects, bad scopes, missing PKCE", %{app: app} do
      assert {:error, :unknown_client} =
               OAuth.validate_authorize(authorize_params(app, %{"client_id" => "nope"}))

      assert {:error, :invalid_redirect_uri} =
               OAuth.validate_authorize(
                 authorize_params(app, %{"redirect_uri" => "https://elsewhere.example.org/cb"})
               )

      assert {:error, :invalid_scope} =
               OAuth.validate_authorize(authorize_params(app, %{"scope" => "root:everything"}))

      assert {:error, :invalid_pkce} =
               OAuth.validate_authorize(Map.delete(authorize_params(app), "code_challenge"))

      assert {:error, :unsupported_response_type} =
               OAuth.validate_authorize(authorize_params(app, %{"response_type" => "token"}))
    end

    test "a suspended app cannot start the flow", %{app: app} do
      ApiAuth.suspend_app!(app)
      assert {:error, :app_suspended} = OAuth.validate_authorize(authorize_params(app))
    end
  end

  describe "code exchange" do
    test "the happy path mints a working access/refresh pair", %{
      member: member,
      app: app,
      secret: secret
    } do
      assert {:ok, tokens} = run_flow(member, app, secret)
      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == OAuth.access_ttl_seconds()
      assert String.starts_with?(tokens.access_token, "vutuv_at_")
      assert String.starts_with?(tokens.refresh_token, "vutuv_rt_")

      assert {:ok, token, user} = ApiAuth.verify_token(tokens.access_token)
      assert user.id == member.id
      assert token.scopes == ["profile:read", "posts:write"]
    end

    test "a wrong PKCE verifier fails", %{member: member, app: app, secret: secret} do
      {:ok, request} = OAuth.validate_authorize(authorize_params(app))
      {:ok, code} = OAuth.approve(member, request)

      assert {:error, :invalid_grant} =
               OAuth.exchange(%{
                 "grant_type" => "authorization_code",
                 "client_id" => app.client_id,
                 "client_secret" => secret,
                 "code" => code,
                 "redirect_uri" => @redirect,
                 "code_verifier" => String.duplicate("w", 50)
               })
    end

    test "a wrong secret is invalid_client", %{member: member, app: app} do
      assert {:error, :invalid_client} = run_flow(member, app, "vutuv_sec_wrong")
    end

    test "redeeming a code twice revokes the grant's tokens", %{
      member: member,
      app: app,
      secret: secret
    } do
      {:ok, request} = OAuth.validate_authorize(authorize_params(app))
      {:ok, code} = OAuth.approve(member, request)

      exchange = fn ->
        OAuth.exchange(%{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier()
        })
      end

      assert {:ok, tokens} = exchange.()
      assert {:error, :invalid_grant} = exchange.()
      assert {:error, :revoked} = ApiAuth.verify_token(tokens.access_token)
    end
  end

  describe "refresh rotation" do
    test "rotates the pair; the old refresh token stops working and its reuse kills everything",
         %{member: member, app: app, secret: secret} do
      {:ok, first} = run_flow(member, app, secret)

      refresh = fn token ->
        OAuth.refresh(%{
          "grant_type" => "refresh_token",
          "client_id" => app.client_id,
          "client_secret" => secret,
          "refresh_token" => token
        })
      end

      assert {:ok, second} = refresh.(first.refresh_token)
      assert second.access_token != first.access_token
      assert {:ok, _, _} = ApiAuth.verify_token(second.access_token)

      # Reusing the rotated token is the theft signal: everything dies.
      assert {:error, :invalid_grant} = refresh.(first.refresh_token)
      assert {:error, :revoked} = ApiAuth.verify_token(second.access_token)
    end
  end

  describe "grant management" do
    test "revoking the grant kills its tokens; re-consent revives the grant", %{
      member: member,
      app: app,
      secret: secret
    } do
      {:ok, tokens} = run_flow(member, app, secret)

      assert [grant] = ApiAuth.list_grants(member)
      assert grant.app.id == app.id

      ApiAuth.revoke_grant!(grant)
      assert {:error, :revoked} = ApiAuth.verify_token(tokens.access_token)
      assert ApiAuth.list_grants(member) == []

      assert {:ok, fresh} = run_flow(member, app, secret)
      assert {:ok, _, _} = ApiAuth.verify_token(fresh.access_token)
      assert [_grant] = ApiAuth.list_grants(member)
    end

    test "re-consent after revocation grants only the freshly approved scopes", %{
      member: member,
      app: app,
      secret: secret
    } do
      # First authorize with two scopes, then explicitly revoke.
      {:ok, tokens} = run_flow(member, app, secret)
      assert {:ok, token, _} = ApiAuth.verify_token(tokens.access_token)
      assert Enum.sort(token.scopes) == ["posts:write", "profile:read"]

      [grant] = ApiAuth.list_grants(member)
      ApiAuth.revoke_grant!(grant)

      # Re-authorize requesting ONLY profile:read — the revoked posts:write
      # must not resurrect through the union.
      {:ok, request} =
        OAuth.validate_authorize(authorize_params(app, %{"scope" => "profile:read"}))

      {:ok, code} = OAuth.approve(member, request)

      {:ok, fresh} =
        OAuth.exchange(%{
          "grant_type" => "authorization_code",
          "client_id" => app.client_id,
          "client_secret" => secret,
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier()
        })

      assert {:ok, fresh_token, _} = ApiAuth.verify_token(fresh.access_token)
      assert fresh_token.scopes == ["profile:read"]

      [regrant] = ApiAuth.list_grants(member)
      assert regrant.scopes == ["profile:read"]
    end

    test "consent widens scopes (union), never narrows", %{member: member, app: app} do
      {:ok, request} = OAuth.validate_authorize(authorize_params(app))
      {:ok, _code} = OAuth.approve(member, request)

      {:ok, request2} =
        OAuth.validate_authorize(authorize_params(app, %{"scope" => "messages:read"}))

      {:ok, _code2} = OAuth.approve(member, request2)

      assert [grant] = ApiAuth.list_grants(member)
      assert Enum.sort(grant.scopes) == ["messages:read", "posts:write", "profile:read"]
    end

    test "concurrent first authorizes don't crash on the grant unique index", %{
      member: member,
      app: app
    } do
      {:ok, request} = OAuth.validate_authorize(authorize_params(app))

      results =
        Task.await_many(for _ <- 1..4, do: Task.async(fn -> OAuth.approve(member, request) end))

      # No first-mint race may surface a raw unique-violation 500: every
      # consent either creates the grant or folds into the winner's row.
      assert Enum.all?(results, &match?({:ok, _code}, &1))
      assert [_one] = ApiAuth.list_grants(member)
    end
  end

  describe "revoke/1 (RFC 7009)" do
    test "revoking a refresh token kills the pair; unknown tokens are still :ok", %{
      member: member,
      app: app,
      secret: secret
    } do
      {:ok, tokens} = run_flow(member, app, secret)

      assert :ok =
               OAuth.revoke(%{
                 "client_id" => app.client_id,
                 "client_secret" => secret,
                 "token" => tokens.refresh_token
               })

      assert {:error, :revoked} = ApiAuth.verify_token(tokens.access_token)

      assert :ok =
               OAuth.revoke(%{
                 "client_id" => app.client_id,
                 "client_secret" => secret,
                 "token" => "vutuv_at_unknown"
               })
    end
  end
end
