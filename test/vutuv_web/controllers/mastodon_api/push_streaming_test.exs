defmodule VutuvWeb.MastodonApi.PushStreamingTest do
  @moduledoc """
  Web Push subscriptions and the crypto behind them.

  `async: false` because both keys this flips — `:web_push_enabled` and
  `:web_push` — are application config, and every push path in the app reads
  them. `config/test.exs` holds push **off** for the rest of the suite (the
  dispatcher runs on every notification and would fire a real request at a push
  service), so a test here says which state it wants.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.MastodonApi.PushSubscription
  alias Vutuv.MastodonApi.WebPush
  alias Vutuv.Repo

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp enable_push, do: put_config(:web_push_enabled, true)
  defp with_vapid(keys), do: put_config(:web_push, keys)

  # Push on, with a pinned pair — what an operator who set the env vars has.
  defp pinned_keys do
    keys = Vutuv.WebPush.generate_keys()
    enable_push()
    with_vapid(vapid_public_key: keys.public_key, vapid_private_key: keys.private_key)
    keys
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
      %{public_key: public, private_key: private} = Vutuv.WebPush.generate_keys()

      assert {:ok, decoded_public} = Base.url_decode64(public, padding: false)
      assert byte_size(decoded_public) == 65
      assert {:ok, decoded_private} = Base.url_decode64(private, padding: false)
      assert byte_size(decoded_private) == 32
    end

    # The bug the regression tests below are about: an installation nobody
    # configured had no key, so every client was told push does not exist here.
    test "an installation that configured nothing still has a key pair" do
      enable_push()
      with_vapid([])

      assert WebPush.enabled?()
      assert {:ok, public} = Base.url_decode64(WebPush.public_key(), padding: false)
      assert byte_size(public) == 65
      assert WebPush.public_key() == WebPush.public_key(), "the derived pair must be stable"
    end

    # A key pair is only a key pair if the private half signs for the public
    # one, which a length check does not show. The private half never leaves
    # the module, so the test re-walks the derivation itself — which also pins
    # the domain-separation string, and that is the point: changing it silently
    # invalidates every subscription every phone already registered.
    test "the advertised key is the point of the derived private scalar" do
      enable_push()
      with_vapid([])

      secret = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]
      scalar = :crypto.hash(:sha256, "vutuv/web_push/vapid/v1/0" <> secret)
      {public, _private} = :crypto.generate_key(:ecdh, :prime256v1, scalar)

      assert Base.url_encode64(public, padding: false) == WebPush.public_key()
    end

    # Push is the phone-client API, so the adapter's own switch has to take it
    # along — a device that subscribed before `MASTODON_API_ENABLED=false` must
    # not keep being pushed to from an installation that answers 404 to every
    # request that device makes.
    test "the adapter's switch takes push with it" do
      enable_push()
      put_config(:mastodon_api_enabled, false)

      refute WebPush.enabled?()
      refute WebPush.public_key()
    end

    # Half a pair is a signature no push service accepts, so it must not be
    # mixed with the derived other half — the whole pair falls back instead.
    test "a configured pair wins, and half a pair is ignored" do
      keys = pinned_keys()
      assert WebPush.public_key() == keys.public_key

      with_vapid(vapid_public_key: keys.public_key)
      refute WebPush.public_key() == keys.public_key
      assert {:ok, decoded} = Base.url_decode64(WebPush.public_key(), padding: false)
      assert byte_size(decoded) == 65
    end

    test "an operator who turned push off has no key and no push" do
      put_config(:web_push_enabled, false)

      refute WebPush.enabled?()
      refute WebPush.public_key()
    end
  end

  # The public key has to be where a current client looks for it: Mastodon moved
  # it into the instance document in 4.3 and deprecated the `vapid_key` in the
  # answer to `POST /api/v1/apps` at the same time. We claim 4.4 compatibility.
  describe "GET /api/v2/instance" do
    test "names the server's VAPID key", %{conn: conn} do
      keys = pinned_keys()

      body = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)

      assert body["configuration"]["vapid"]["public_key"] == keys.public_key
    end

    test "an installation with push off names none at all", %{conn: conn} do
      put_config(:web_push_enabled, false)

      body = conn |> on_mastodon_host() |> get("/api/v2/instance") |> json_response(200)

      refute Map.has_key?(body["configuration"], "vapid")
    end
  end

  describe "POST /api/v1/push/subscription" do
    test "registers a device and answers the server key", %{conn: conn} do
      keys = pinned_keys()

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
      pinned_keys()

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
      pinned_keys()

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

    # The reported bug, end to end: a client on an installation whose operator
    # never heard of VAPID could not switch push on.
    test "registers on an installation that configured nothing", %{conn: conn} do
      enable_push()
      with_vapid([])

      token = mastodon_token(insert(:activated_user), ["push"])

      body =
        conn
        |> mastodon_conn(token)
        |> post("/api/v1/push/subscription", %{
          "subscription" => %{
            "endpoint" => "https://push.example.com/abc",
            "keys" => browser_keys()
          }
        })
        |> json_response(200)

      assert body["server_key"] == WebPush.public_key()
      assert Repo.aggregate(PushSubscription, :count) == 1
    end

    test "an installation with push off refuses instead of accepting a dead subscription", %{
      conn: conn
    } do
      put_config(:web_push_enabled, false)
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
      pinned_keys()

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

    # Issue #1698: the clients were written against Mastodon, which defaults
    # this to false — so a client that says nothing has to be recorded as
    # legacy, or its phone is sent a body it cannot open.
    test "a client that sends no flag is recorded as legacy" do
      pinned_keys()

      user = insert(:activated_user)

      body =
        build_conn()
        |> mastodon_conn(mastodon_token(user, ["push"]))
        |> post("/api/v1/push/subscription", %{
          "subscription" => %{
            "endpoint" => "https://push.example.com/abc",
            "keys" => browser_keys()
          }
        })
        |> json_response(200)

      assert body["standard"] == false
      refute Repo.get_by!(PushSubscription, user_id: user.id).standard
    end

    # However the client's HTTP library felt like spelling a boolean. A value
    # Ecto refuses to cast would answer 422 to a subscription that is otherwise
    # perfectly good, leaving that device with no push at all.
    test "the flag is read however the client spells it" do
      pinned_keys()

      for {sent, stored} <- [{true, true}, {"true", true}, {"1", true}, {"0", false}] do
        user = insert(:activated_user)

        body =
          build_conn()
          |> mastodon_conn(mastodon_token(user, ["push"]))
          |> post("/api/v1/push/subscription", %{
            "subscription" => %{
              "endpoint" => "https://push.example.com/abc",
              "keys" => browser_keys(),
              "standard" => sent
            }
          })
          |> json_response(200)

        assert body["standard"] == stored, "#{inspect(sent)} answered #{body["standard"]}"
        assert Repo.get_by!(PushSubscription, user_id: user.id).standard == stored
      end
    end

    # The same device, resubscribed by a build that has since learned the
    # standard encoding — or by an older one that has not. The flag has to
    # follow the new subscription, never survive from the row it replaces.
    test "re-registering rewrites the flag rather than keeping the old one" do
      pinned_keys()

      token = mastodon_token(insert(:activated_user), ["push"])

      for standard <- [true, false] do
        build_conn()
        |> mastodon_conn(token)
        |> post("/api/v1/push/subscription", %{
          "subscription" => %{
            "endpoint" => "https://push.example.com/abc",
            "keys" => browser_keys(),
            "standard" => standard
          }
        })
        |> json_response(200)

        assert Repo.one(PushSubscription).standard == standard
      end
    end

    test "reading and deleting the subscription", %{conn: conn} do
      pinned_keys()

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
      pinned_keys()

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
