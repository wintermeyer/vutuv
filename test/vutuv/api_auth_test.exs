defmodule Vutuv.ApiAuthTest do
  use Vutuv.DataCase, async: true
  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.{Scopes, Token}

  describe "create_pat/2" do
    test "mints a prefixed token and stores only its hash" do
      user = insert_activated_user()

      assert {:ok, plaintext, %Token{} = token} =
               ApiAuth.create_pat(user, %{"name" => "CLI", "scopes" => ["profile:read"]})

      assert String.starts_with?(plaintext, "vutuv_pat_")
      assert token.kind == "pat"
      assert token.name == "CLI"
      assert token.scopes == ["profile:read"]
      refute token.token_hash =~ plaintext
      refute Repo.get(Token, token.id).token_hash == plaintext
    end

    test "rejects unknown scopes and empty scope lists" do
      user = insert_activated_user()

      assert {:error, changeset} =
               ApiAuth.create_pat(user, %{"name" => "CLI", "scopes" => ["root:everything"]})

      assert %{scopes: _} = errors_on(changeset)

      assert {:error, changeset} = ApiAuth.create_pat(user, %{"name" => "CLI", "scopes" => []})
      assert %{scopes: _} = errors_on(changeset)
    end

    test "requires a name" do
      user = insert_activated_user()

      assert {:error, changeset} =
               ApiAuth.create_pat(user, %{"name" => "", "scopes" => ["profile:read"]})

      assert %{name: _} = errors_on(changeset)
    end

    # The "every token expires" policy lives here in the minting chokepoint,
    # not in the web form — no caller can mint an eternal token by omission.
    test "defaults the expiry to 90 days when none is given" do
      user = insert_activated_user()

      assert {:ok, _plaintext, token} =
               ApiAuth.create_pat(user, %{"name" => "CLI", "scopes" => ["profile:read"]})

      assert %DateTime{} = token.expires_at
      assert DateTime.diff(token.expires_at, DateTime.utc_now(), :day) in 89..90
    end

    test "an explicit expiry wins over the default" do
      user = insert_activated_user()
      next_week = DateTime.add(DateTime.utc_now(:second), 7 * 86_400)

      assert {:ok, _plaintext, token} =
               ApiAuth.create_pat(user, %{
                 "name" => "CLI",
                 "scopes" => ["profile:read"],
                 "expires_at" => next_week
               })

      assert DateTime.compare(token.expires_at, next_week) == :eq
    end
  end

  describe "verify_token/1" do
    test "returns the token and its user for a valid PAT" do
      user = insert_activated_user()
      {:ok, plaintext, _token} = ApiAuth.create_pat(user, pat_attrs())

      assert {:ok, %Token{} = token, verified_user} = ApiAuth.verify_token(plaintext)
      assert verified_user.id == user.id
      assert token.user_id == user.id
      assert %DateTime{} = token.last_used_at
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_token} = ApiAuth.verify_token("vutuv_pat_nonexistent")
    end

    test "rejects a revoked token immediately" do
      user = insert_activated_user()
      {:ok, plaintext, token} = ApiAuth.create_pat(user, pat_attrs())

      ApiAuth.revoke_token!(token)

      assert {:error, :revoked} = ApiAuth.verify_token(plaintext)
    end

    test "rejects an expired token" do
      user = insert_activated_user()
      yesterday = DateTime.add(DateTime.utc_now(:second), -1, :day)

      {:ok, plaintext, _token} =
        ApiAuth.create_pat(user, Map.put(pat_attrs(), "expires_at", yesterday))

      assert {:error, :expired} = ApiAuth.verify_token(plaintext)
    end

    test "rejects tokens of unactivated users" do
      user = insert(:user, email_confirmed?: false)
      {:ok, plaintext, _token} = ApiAuth.create_pat(user, pat_attrs())

      assert {:error, :account_inactive} = ApiAuth.verify_token(plaintext)
    end

    test "rejects tokens of a suspended app immediately" do
      user = insert_activated_user()
      app = insert(:oauth_app)
      plaintext = "vutuv_at_suspended_app_test"

      insert(:api_token,
        user: user,
        app: app,
        kind: "access",
        token_hash: Vutuv.ApiAuth.hash_token(plaintext),
        scopes: ["profile:read"]
      )

      assert {:ok, _token, _user} = ApiAuth.verify_token(plaintext)

      app
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:error, :app_suspended} = ApiAuth.verify_token(plaintext)
    end

    test "rejects tokens of suspended and deactivated users" do
      until = NaiveDateTime.add(NaiveDateTime.utc_now(:second), 86_400)
      suspended = insert_activated_user(suspended_until: until)
      {:ok, plaintext, _token} = ApiAuth.create_pat(suspended, pat_attrs())

      assert {:error, :account_inactive} = ApiAuth.verify_token(plaintext)

      deactivated = insert_activated_user(deactivated_at: NaiveDateTime.utc_now(:second))
      {:ok, plaintext, _token} = ApiAuth.create_pat(deactivated, pat_attrs())

      assert {:error, :account_inactive} = ApiAuth.verify_token(plaintext)
    end
  end

  describe "revocation" do
    test "revoke_token!/1 sets revoked_at and list_pats/1 drops the token" do
      user = insert_activated_user()
      {:ok, _plaintext, token} = ApiAuth.create_pat(user, pat_attrs())

      assert [%Token{}] = ApiAuth.list_pats(user)
      revoked = ApiAuth.revoke_token!(token)
      assert %DateTime{} = revoked.revoked_at
      assert ApiAuth.list_pats(user) == []
    end

    test "revoke_all_tokens!/1 kills every credential of the user at once" do
      user = insert_activated_user()
      {:ok, one, _} = ApiAuth.create_pat(user, pat_attrs())
      {:ok, two, _} = ApiAuth.create_pat(user, pat_attrs("Other"))

      other_user = insert_activated_user()
      {:ok, keep, _} = ApiAuth.create_pat(other_user, pat_attrs())

      assert ApiAuth.revoke_all_tokens!(user) == 2
      assert {:error, :revoked} = ApiAuth.verify_token(one)
      assert {:error, :revoked} = ApiAuth.verify_token(two)
      assert {:ok, _, _} = ApiAuth.verify_token(keep)
    end

    test "get_pat/2 scopes to the owner" do
      user = insert_activated_user()
      other = insert_activated_user()
      {:ok, _plaintext, token} = ApiAuth.create_pat(user, pat_attrs())

      assert %Token{} = ApiAuth.get_pat(user, token.id)
      assert ApiAuth.get_pat(other, token.id) == nil
    end
  end

  describe "Scopes" do
    test "granted?/2: a write scope implies its read sibling" do
      assert Scopes.granted?(["posts:write"], "posts:read")
      assert Scopes.granted?(["posts:read"], "posts:read")
      refute Scopes.granted?(["posts:read"], "posts:write")
      refute Scopes.granted?(["profile:write"], "posts:read")
    end

    test "every scope has a description for the consent/PAT UI" do
      for scope <- Scopes.all() do
        assert is_binary(Scopes.description(scope))
        assert Scopes.description(scope) != ""
      end
    end
  end

  defp pat_attrs(name \\ "Test token") do
    %{"name" => name, "scopes" => ["profile:read", "posts:write"]}
  end
end
