defmodule VutuvWeb.MastodonApi.PushStreamingTest do
  @moduledoc """
  Web Push subscriptions and the crypto behind them.

  `async: false` because the VAPID key pair is application config, and every
  push path in the app reads it.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.ApiAuth
  alias Vutuv.MastodonApi.PushSubscription
  alias Vutuv.MastodonApi.WebPush
  alias Vutuv.Repo

  @mastodon_host "mastodon.localhost"

  defp token_for(user, scopes) do
    plaintext = "vutuv_at_" <> ApiAuth.random_token()
    app = insert(:oauth_app, user: nil, protocol: "mastodon", registered_scopes: scopes)

    insert(:api_token,
      user: user,
      app: app,
      kind: "access",
      name: nil,
      scopes: scopes,
      expires_at: nil,
      token_hash: ApiAuth.hash_token(plaintext)
    )

    plaintext
  end

  defp api(conn, token) do
    conn
    |> Map.put(:host, @mastodon_host)
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp with_vapid(keys) do
    original = Application.fetch_env(:vutuv, :web_push)
    Application.put_env(:vutuv, :web_push, keys)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:vutuv, :web_push, value)
        :error -> Application.delete_env(:vutuv, :web_push)
      end
    end)
  end

  # A browser subscription: the key is an uncompressed P-256 point, the auth
  # secret 16 bytes.
  defp browser_keys do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "p256dh" => Base.url_encode64(public, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end

  describe "VAPID keys" do
    test "generate_keys/0 produces a usable pair" do
      %{public_key: public, private_key: private} = WebPush.generate_keys()

      assert {:ok, decoded_public} = Base.url_decode64(public, padding: false)
      assert byte_size(decoded_public) == 65
      assert {:ok, decoded_private} = Base.url_decode64(private, padding: false)
      assert byte_size(decoded_private) == 32
    end

    test "push is off until an operator configures a pair" do
      with_vapid([])
      refute WebPush.configured?()

      keys = WebPush.generate_keys()
      with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)
      assert WebPush.configured?()
    end
  end

  describe "POST /api/v1/push/subscription" do
    test "registers a device and answers the server key", %{conn: conn} do
      keys = WebPush.generate_keys()
      with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)

      user = insert(:activated_user)
      token = token_for(user, ["push"])

      body =
        conn
        |> api(token)
        |> post("/api/v1/push/subscription", %{
          "subscription" => %{
            "endpoint" => "https://push.example.com/abc",
            "keys" => browser_keys()
          },
          "data" => %{"alerts" => %{"mention" => true, "follow" => false}}
        })
        |> json_response(200)

      assert body["server_key"] == keys.public_key
      assert body["alerts"]["mention"] == true
      assert body["alerts"]["follow"] == false

      assert Repo.aggregate(PushSubscription, :count) == 1
    end

    test "an endpoint that is not https is refused", %{conn: conn} do
      keys = WebPush.generate_keys()
      with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)

      token = token_for(insert(:activated_user), ["push"])

      assert conn
             |> api(token)
             |> post("/api/v1/push/subscription", %{
               "subscription" => %{
                 "endpoint" => "http://push.example.com/abc",
                 "keys" => browser_keys()
               }
             })
             |> response(422)
    end

    test "without VAPID keys the endpoint refuses instead of accepting a dead subscription", %{
      conn: conn
    } do
      with_vapid([])
      token = token_for(insert(:activated_user), ["push"])

      assert conn
             |> api(token)
             |> post("/api/v1/push/subscription", %{
               "subscription" => %{
                 "endpoint" => "https://push.example.com/abc",
                 "keys" => browser_keys()
               }
             })
             |> response(403)
    end

    test "re-registering the same token replaces its subscription" do
      keys = WebPush.generate_keys()
      with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)

      token = token_for(insert(:activated_user), ["push"])

      for endpoint <- ["https://push.example.com/one", "https://push.example.com/two"] do
        build_conn()
        |> api(token)
        |> post("/api/v1/push/subscription", %{
          "subscription" => %{"endpoint" => endpoint, "keys" => browser_keys()}
        })
        |> json_response(200)
      end

      assert Repo.aggregate(PushSubscription, :count) == 1
      assert Repo.one(PushSubscription).endpoint == "https://push.example.com/two"
    end

    test "reading and deleting the subscription", %{conn: conn} do
      keys = WebPush.generate_keys()
      with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)

      token = token_for(insert(:activated_user), ["push"])

      conn
      |> api(token)
      |> post("/api/v1/push/subscription", %{
        "subscription" => %{"endpoint" => "https://push.example.com/x", "keys" => browser_keys()}
      })
      |> json_response(200)

      assert build_conn()
             |> api(token)
             |> get("/api/v1/push/subscription")
             |> json_response(200)

      assert build_conn()
             |> api(token)
             |> delete("/api/v1/push/subscription")
             |> json_response(200) == %{}

      assert Repo.aggregate(PushSubscription, :count) == 0
    end
  end
end
