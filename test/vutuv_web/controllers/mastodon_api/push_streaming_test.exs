defmodule VutuvWeb.MastodonApi.PushStreamingTest do
  @moduledoc """
  Web Push subscriptions and the crypto behind them.

  `async: false` because the VAPID key pair is application config, and every
  push path in the app reads it.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.MastodonApi.PushSubscription
  alias Vutuv.MastodonApi.WebPush
  alias Vutuv.Repo

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
      token = mastodon_token(user, ["push"])

      body =
        conn
        |> mastodon_conn(token)
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

      token = mastodon_token(insert(:activated_user), ["push"])

      assert conn
             |> mastodon_conn(token)
             |> post("/api/v1/push/subscription", %{
               "subscription" => %{
                 "endpoint" => "http://push.example.com/abc",
                 "keys" => browser_keys()
               }
             })
             |> response(422)
    end

    # https alone is not the check: `https://10.0.0.5/` is a perfectly good
    # https URL, and a stored endpoint is a URL this server will POST to later.
    # Same hazard, and same guard, as a webhook target.
    test "an endpoint pointing into our own network is refused" do
      keys = WebPush.generate_keys()
      with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)

      token = mastodon_token(insert(:activated_user), ["push"])

      for endpoint <- [
            "https://127.0.0.1/push",
            "https://localhost/push",
            "https://10.0.0.5/push",
            "https://169.254.169.254/latest/meta-data"
          ] do
        assert build_conn()
               |> mastodon_conn(token)
               |> post("/api/v1/push/subscription", %{
                 "subscription" => %{"endpoint" => endpoint, "keys" => browser_keys()}
               })
               |> response(422),
               "#{endpoint} was accepted"
      end

      assert Repo.aggregate(PushSubscription, :count) == 0
    end

    test "without VAPID keys the endpoint refuses instead of accepting a dead subscription", %{
      conn: conn
    } do
      with_vapid([])
      token = mastodon_token(insert(:activated_user), ["push"])

      assert conn
             |> mastodon_conn(token)
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

      token = mastodon_token(insert(:activated_user), ["push"])

      for endpoint <- ["https://push.example.com/one", "https://push.example.com/two"] do
        build_conn()
        |> mastodon_conn(token)
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

      token = mastodon_token(insert(:activated_user), ["push"])

      conn
      |> mastodon_conn(token)
      |> post("/api/v1/push/subscription", %{
        "subscription" => %{"endpoint" => "https://push.example.com/x", "keys" => browser_keys()}
      })
      |> json_response(200)

      assert build_conn()
             |> mastodon_conn(token)
             |> get("/api/v1/push/subscription")
             |> json_response(200)

      assert build_conn()
             |> mastodon_conn(token)
             |> delete("/api/v1/push/subscription")
             |> json_response(200) == %{}

      assert Repo.aggregate(PushSubscription, :count) == 0
    end
  end

  # The changeset can only judge the literal it is handed. A hostname that was
  # public when the subscription was written can be re-pointed at an internal
  # address afterwards, and stored-then-fetched means those are two different
  # moments — so the resolving half runs at send time.
  describe "sending to a host that resolves inward" do
    setup do
      previous = Application.get_env(:vutuv, :ssrf_resolver)
      on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, previous) end)
      :ok
    end

    test "is refused before any request is made" do
      keys = WebPush.generate_keys()
      with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)

      Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family ->
        {:ok, [{169, 254, 169, 254}]}
      end)

      subscription = Map.put(browser_keys(), "endpoint", "https://push.example.com/abc")

      assert WebPush.send(
               %{
                 endpoint: subscription["endpoint"],
                 p256dh: subscription["p256dh"],
                 auth: subscription["auth"]
               },
               %{notification_id: "x"}
             ) == {:error, :blocked}
    end
  end
end
