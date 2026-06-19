defmodule Vutuv.WebhooksTest do
  use Vutuv.DataCase

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.OAuth
  alias Vutuv.Webhooks
  alias Vutuv.Webhooks.{Delivery, Subscription}

  @redirect "https://app.example.org/callback"

  setup do
    developer = insert_activated_user()
    member = insert_activated_user()

    {:ok, app, _secret} =
      ApiAuth.create_app(developer, %{"name" => "Hook App", "redirect_uris" => [@redirect]})

    {:ok, developer: developer, member: member, app: app}
  end

  defp grant!(member, app, scopes) do
    {:ok, request} =
      OAuth.validate_authorize(%{
        "response_type" => "code",
        "client_id" => app.client_id,
        "redirect_uri" => @redirect,
        "scope" => Enum.join(scopes, " "),
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, "vvvvv"), padding: false),
        "code_challenge_method" => "S256"
      })

    {:ok, _code} = OAuth.approve(member, request)
    :ok
  end

  defp subscribe!(app, events) do
    {:ok, subscription, secret} =
      Webhooks.create_subscription(app, %{
        "url" => "https://hooks.example.org/vutuv",
        "events" => events
      })

    {subscription, secret}
  end

  defp stub_endpoint(fun) do
    Application.put_env(:vutuv, :webhook_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :webhook_req_options) end)
  end

  describe "subscriptions" do
    test "validates url and events", %{app: app} do
      assert {:error, changeset} =
               Webhooks.create_subscription(app, %{
                 "url" => "http://evil.example.org",
                 "events" => ["ping?"]
               })

      assert %{url: _, events: _} = errors_on(changeset)

      assert {:error, changeset} =
               Webhooks.create_subscription(app, %{
                 "url" => "https://ok.example.org",
                 "events" => []
               })

      assert %{events: _} = errors_on(changeset)

      assert {:ok, subscription, secret} = subscribe_ok(app)
      assert String.starts_with?(secret, "vutuv_whsec_")
      refute subscription.secret == nil
    end

    defp subscribe_ok(app) do
      Webhooks.create_subscription(app, %{
        "url" => "https://hooks.example.org/x",
        "events" => ["follower.created"]
      })
    end

    test "rejects URLs pointing at private, loopback or metadata addresses (SSRF)", %{app: app} do
      # Webhook delivery is a server-side POST, so any authenticated developer
      # could otherwise make us hit the cloud-metadata endpoint or an internal
      # host (issue #775). The same gate the profile-link screenshots use.
      internal = [
        "https://169.254.169.254/latest/meta-data/",
        "https://10.0.0.5/hook",
        "https://192.168.1.1/hook",
        "https://[::1]/hook",
        "http://localhost/hook",
        "https://127.0.0.1/hook"
      ]

      for url <- internal do
        assert {:error, changeset} =
                 Webhooks.create_subscription(app, %{
                   "url" => url,
                   "events" => ["follower.created"]
                 }),
               "expected #{url} to be rejected as an internal target"

        assert %{url: _} = errors_on(changeset)
      end

      # A normal public https endpoint is still accepted.
      assert {:ok, _sub, _secret} =
               Webhooks.create_subscription(app, %{
                 "url" => "https://hooks.example.org/ok",
                 "events" => ["follower.created"]
               })
    end
  end

  describe "emit/3" do
    test "queues only for apps the member authorized with the matching scope", %{
      member: member,
      app: app,
      developer: developer
    } do
      {subscription, _secret} = subscribe!(app, ["follower.created", "post.liked"])

      # No grant yet: nothing is queued.
      Webhooks.emit(member.id, "follower.created", %{"follower" => "someone"})
      assert Repo.aggregate(Delivery, :count) == 0

      grant!(member, app, ["social:read"])

      Webhooks.emit(member.id, "follower.created", %{"follower" => "someone"})
      assert [delivery] = Repo.all(Delivery)
      assert delivery.subscription_id == subscription.id
      assert delivery.event == "follower.created"
      assert delivery.payload["member"] == member.username
      assert delivery.payload["data"] == %{"follower" => "someone"}

      # The granted scope does not cover posts events: nothing for a like.
      Webhooks.emit(member.id, "post.liked", %{"by" => "someone", "post_id" => "x"})
      assert Repo.aggregate(Delivery, :count) == 1

      # Another developer's unauthorized app hears nothing either.
      {:ok, other_app, _} =
        ApiAuth.create_app(developer, %{"name" => "Other", "redirect_uris" => [@redirect]})

      subscribe!(other_app, ["follower.created"])
      Webhooks.emit(member.id, "follower.created", %{"follower" => "someone"})

      assert Repo.aggregate(
               from(d in Delivery, where: d.subscription_id == ^subscription.id),
               :count
             ) == 2

      assert Repo.aggregate(Delivery, :count) == 2
    end

    test "suspended apps and revoked grants hear nothing", %{member: member, app: app} do
      subscribe!(app, ["follower.created"])
      grant!(member, app, ["social:read"])

      ApiAuth.suspend_app!(app)
      Webhooks.emit(member.id, "follower.created", %{})
      assert Repo.aggregate(Delivery, :count) == 0

      ApiAuth.unsuspend_app!(app)
      [grant] = ApiAuth.list_grants(member)
      ApiAuth.revoke_grant!(grant)
      Webhooks.emit(member.id, "follower.created", %{})
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "the real chokepoint queues it: a follow emits follower.created", %{
      member: member,
      app: app
    } do
      subscribe!(app, ["follower.created"])
      grant!(member, app, ["social:read"])

      follower = insert_activated_user()
      {:ok, _} = Vutuv.Social.follow(follower, member.id)

      assert [delivery] = Repo.all(Delivery)
      assert delivery.event == "follower.created"
      assert delivery.payload["data"]["follower"] == follower.username
    end
  end

  describe "deliver_due/0" do
    test "posts the signed envelope; 2xx closes the delivery", %{member: member, app: app} do
      {_subscription, secret} = subscribe!(app, ["follower.created"])
      grant!(member, app, ["social:read"])
      Webhooks.emit(member.id, "follower.created", %{"follower" => "anna"})

      parent = self()

      stub_endpoint(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:delivered, body, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert Webhooks.deliver_due() == 1
      assert_receive {:delivered, body, headers}

      assert %{"event" => "follower.created", "data" => %{"follower" => "anna"}} =
               Jason.decode!(body)

      headers = Map.new(headers)
      assert headers["x-vutuv-event"] == "follower.created"
      assert headers["x-vutuv-signature"] == "sha256=" <> Webhooks.sign(body, secret)

      assert [%Delivery{delivered_at: %DateTime{}, last_status: 200}] = Repo.all(Delivery)
      # Nothing left to do.
      assert Webhooks.deliver_due() == 0
    end

    test "failures back off and eventually disable the subscription", %{member: member, app: app} do
      {subscription, _secret} = subscribe!(app, ["follower.created"])
      grant!(member, app, ["social:read"])
      Webhooks.emit(member.id, "follower.created", %{})

      stub_endpoint(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert Webhooks.deliver_due() == 1

      [delivery] = Repo.all(Delivery)
      assert delivery.delivered_at == nil
      assert delivery.attempts == 1
      assert delivery.last_status == 500
      assert DateTime.compare(delivery.next_attempt_at, DateTime.utc_now()) == :gt

      # Not due anymore until the backoff elapses.
      assert Webhooks.deliver_due() == 0

      assert Repo.get(Subscription, subscription.id).consecutive_failures == 1

      # One failure away from the kill threshold: the next one disables it.
      subscription
      |> Ecto.Changeset.change(consecutive_failures: 29)
      |> Repo.update!()

      Repo.update!(Ecto.Changeset.change(delivery, next_attempt_at: DateTime.utc_now(:second)))

      assert Webhooks.deliver_due() == 1
      reloaded = Repo.get(Subscription, subscription.id)
      refute reloaded.active?
      assert reloaded.disabled_reason =~ "consecutive"

      # A disabled subscription's queue is not attempted.
      assert Webhooks.deliver_due() == 0

      # The developer can re-enable after fixing their endpoint.
      Webhooks.reactivate!(reloaded)
      assert Repo.get(Subscription, subscription.id).active?
    end

    test "every failing delivery counts toward the failure budget", %{member: member, app: app} do
      {subscription, _secret} = subscribe!(app, ["follower.created"])
      grant!(member, app, ["social:read"])
      Webhooks.emit(member.id, "follower.created", %{"n" => 1})
      Webhooks.emit(member.id, "follower.created", %{"n" => 2})

      stub_endpoint(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      # Both deliveries belong to the same subscription; each failure must
      # increment the failure budget rather than clobber the other's write
      # with its own stale preloaded counter.
      assert Webhooks.deliver_due() == 2
      assert Repo.get(Subscription, subscription.id).consecutive_failures == 2
    end

    test "delivery never follows redirects (SSRF guard)", %{member: member, app: app} do
      {_subscription, _secret} = subscribe!(app, ["follower.created"])
      grant!(member, app, ["social:read"])
      Webhooks.emit(member.id, "follower.created", %{})

      parent = self()

      stub_endpoint(fn conn ->
        send(parent, {:hit, conn.request_path})
        # A misconfigured/malicious endpoint 30x-redirecting to an internal
        # host: Req must not chase it.
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert Webhooks.deliver_due() == 1

      # The original endpoint was hit exactly once; the redirect target never.
      assert_receive {:hit, _}
      refute_receive {:hit, "/latest/meta-data"}

      # A 302 is not a success: the delivery is recorded as failed.
      assert [%Delivery{delivered_at: nil, last_status: 302}] = Repo.all(Delivery)
    end

    test "ping delivers without any grant", %{app: app} do
      {subscription, _secret} = subscribe!(app, ["follower.created"])

      stub_endpoint(fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

      :ok = Webhooks.ping(subscription)
      assert Webhooks.deliver_due() == 1
      assert [%Delivery{event: "ping", delivered_at: %DateTime{}}] = Repo.all(Delivery)
    end

    test "delivery is blocked when the URL resolves to an internal address (DNS rebinding)", %{
      member: member,
      app: app
    } do
      # The subscription was created with a public-looking hostname (the
      # literal-IP gate passed), but its DNS record now points at an internal
      # address (issue #775). Delivery must resolve and refuse before POSTing.
      {subscription, _secret} = subscribe!(app, ["follower.created"])
      grant!(member, app, ["social:read"])
      Webhooks.emit(member.id, "follower.created", %{})

      parent = self()

      stub_endpoint(fn conn ->
        send(parent, {:hit, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      prev = Application.get_env(:vutuv, :ssrf_resolver)
      on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, prev) end)

      Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family ->
        {:ok, [{169, 254, 169, 254}]}
      end)

      assert Webhooks.deliver_due() == 1

      # No POST reached the endpoint, and the delivery is recorded as failed.
      refute_receive {:hit, _}

      assert [%Delivery{delivered_at: nil, last_status: nil, last_error: error}] =
               Repo.all(Delivery)

      assert error =~ "internal"
      assert Repo.get(Subscription, subscription.id).consecutive_failures == 1
    end
  end
end
