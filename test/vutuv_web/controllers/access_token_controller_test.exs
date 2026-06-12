defmodule VutuvWeb.AccessTokenControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth

  describe "as a visitor" do
    test "the token pages are not visible", %{conn: conn} do
      assert get(conn, ~p"/access_tokens").status == 404
      assert get(conn, ~p"/access_tokens/new").status == 404
    end
  end

  describe "logged in" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "index lists the active tokens", %{conn: conn, user: user} do
      {:ok, _plaintext, _token} =
        ApiAuth.create_pat(user, %{"name" => "My import script", "scopes" => ["profile:read"]})

      response = conn |> get(~p"/access_tokens") |> html_response(200)
      assert response =~ "My import script"
      assert response =~ "profile:read"
    end

    test "create shows the token exactly once", %{conn: conn} do
      conn =
        post(conn, ~p"/access_tokens",
          token: %{"name" => "CLI", "scopes" => ["profile:read"], "expires_in" => "90"}
        )

      assert redirected_to(conn) == ~p"/access_tokens"

      # ConnTest recycles the conn between requests, so the session (and its
      # one-shot flash) carries forward like in a browser.
      conn = get(conn, ~p"/access_tokens")
      once = html_response(conn, 200)
      assert [_, plaintext] = Regex.run(~r/(vutuv_pat_[a-z2-7]+)/, once)
      assert {:ok, _token, _user} = ApiAuth.verify_token(plaintext)

      conn = get(conn, ~p"/access_tokens")
      refute html_response(conn, 200) =~ "vutuv_pat_"
    end

    test "create without a name or scopes re-renders the form", %{conn: conn} do
      conn = post(conn, ~p"/access_tokens", token: %{"name" => "", "scopes" => []})
      assert html_response(conn, 422) =~ "editform"
    end

    test "the new form is pre-filled so submitting it untouched just works", %{conn: conn} do
      doc =
        conn
        |> get(~p"/access_tokens/new")
        |> html_response(200)
        |> LazyHTML.from_document()

      # The name carries a recognizable default (it embeds today's date so
      # several click-through tokens stay distinguishable in the list) ...
      assert [default_name] =
               doc |> LazyHTML.query("input#token_name") |> LazyHTML.attribute("value")

      assert default_name =~ Date.to_iso8601(Date.utc_today())

      # ... exactly the quickstart scope is pre-checked ...
      checked = LazyHTML.query(doc, "input[name='token[scopes][]'][checked]")
      assert LazyHTML.attribute(checked, "value") == ["profile:read"]

      # ... and submitting exactly those defaults mints a token.
      conn =
        post(conn, ~p"/access_tokens",
          token: %{"name" => default_name, "scopes" => ["profile:read"], "expires_in" => "90"}
        )

      assert redirected_to(conn) == ~p"/access_tokens"
    end

    test "tokens always expire: no never option, missing choice falls back to 90 days",
         %{conn: conn, user: user} do
      doc =
        conn
        |> get(~p"/access_tokens/new")
        |> html_response(200)
        |> LazyHTML.from_document()

      options = LazyHTML.query(doc, "select#token_expires_in option")
      assert LazyHTML.attribute(options, "value") == ["30", "90", "365"]

      selected = LazyHTML.query(doc, "select#token_expires_in option[selected]")
      assert LazyHTML.attribute(selected, "value") == ["90"]

      # A hand-crafted POST without an expiry choice must not mint an
      # eternal token either.
      post(conn, ~p"/access_tokens", token: %{"name" => "X", "scopes" => ["profile:read"]})
      assert [token] = ApiAuth.list_pats(user)
      assert %DateTime{} = token.expires_at
      assert DateTime.diff(token.expires_at, DateTime.utc_now(), :day) in 89..90
    end

    test "an expiry choice sets expires_at", %{conn: conn, user: user} do
      post(conn, ~p"/access_tokens",
        token: %{"name" => "Short", "scopes" => ["profile:read"], "expires_in" => "30"}
      )

      assert [token] = ApiAuth.list_pats(user)
      assert %DateTime{} = token.expires_at
      assert DateTime.diff(token.expires_at, DateTime.utc_now(), :day) in 29..30
    end

    test "delete revokes the token immediately", %{conn: conn, user: user} do
      {:ok, plaintext, token} =
        ApiAuth.create_pat(user, %{"name" => "CLI", "scopes" => ["profile:read"]})

      conn = delete(conn, ~p"/access_tokens/#{token.id}")
      assert redirected_to(conn) == ~p"/access_tokens"
      assert {:error, :revoked} = ApiAuth.verify_token(plaintext)
    end

    test "cannot revoke someone else's token", %{conn: conn} do
      other = insert_activated_user()

      {:ok, plaintext, token} =
        ApiAuth.create_pat(other, %{"name" => "CLI", "scopes" => ["profile:read"]})

      conn = delete(conn, ~p"/access_tokens/#{token.id}")
      assert conn.status == 404
      assert {:ok, _token, _user} = ApiAuth.verify_token(plaintext)
    end

    test "revoke all kills every token at once", %{conn: conn, user: user} do
      {:ok, one, _} = ApiAuth.create_pat(user, %{"name" => "a", "scopes" => ["profile:read"]})
      {:ok, two, _} = ApiAuth.create_pat(user, %{"name" => "b", "scopes" => ["posts:read"]})

      conn = delete(conn, ~p"/access_tokens")
      assert redirected_to(conn) == ~p"/access_tokens"
      assert {:error, :revoked} = ApiAuth.verify_token(one)
      assert {:error, :revoked} = ApiAuth.verify_token(two)
    end
  end
end
