defmodule VutuvWeb.PushDeviceControllerTest do
  @moduledoc """
  Registering and forgetting the browsers a member wants woken while vutuv is
  closed (issue #1729).

  `async: false` because every test here flips `:web_push_enabled`, which is
  global and read by both push dispatchers and by `VutuvWeb.ShellLive`.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers

  alias Vutuv.WebPush.Subscription
  alias Vutuv.WebPush.Subscriptions

  @endpoint_url "https://push.example.com/abcdef"

  setup %{conn: conn} do
    put_config(:web_push_enabled, true)
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  defp login_second_user(prefix) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> create_and_login_user(registration_attrs(prefix))
  end

  describe "POST /settings/push_devices" do
    # The page posts the browser's own `PushSubscription.toJSON()` verbatim, so
    # this is the shape the web platform defines, not one of ours.
    test "stores the browser's own subscription JSON", %{conn: conn, user: user} do
      conn =
        conn
        |> recycle()
        |> put_req_header(
          "user-agent",
          "Mozilla/5.0 (iPhone) AppleWebKit Version/17.0 Safari/605.1"
        )
        |> post(~p"/settings/push_devices", subscription_json())

      assert json_response(conn, 200) == %{"ok" => true}

      assert [subscription] = Subscriptions.for_user(user.id)
      assert subscription.endpoint == @endpoint_url
      # The label the device list shows, from the same helper the session list
      # under Sign-in & security uses.
      assert subscription.device == "Safari on iPhone"
    end

    # An endpoint is one browser, so the same phone signed in as somebody else
    # has to MOVE the row. A second row would leave the member who used the
    # device last still being woken by it.
    test "moves an endpoint to whoever registers it last", %{conn: conn, user: first} do
      post(conn, ~p"/settings/push_devices", subscription_json())

      {other_conn, second} = login_second_user("second")
      post(other_conn, ~p"/settings/push_devices", subscription_json())

      assert Subscriptions.for_user(first.id) == []
      assert [%Subscription{endpoint: @endpoint_url}] = Subscriptions.for_user(second.id)
    end

    test "refuses an endpoint pointing at an internal address", %{conn: conn, user: user} do
      conn = post(conn, ~p"/settings/push_devices", subscription_json("https://10.0.0.5/push"))

      assert json_response(conn, 422)["ok"] == false
      assert Subscriptions.for_user(user.id) == []
    end

    # The column is `:text`, but it carries a btree unique index, and a btree
    # entry may not exceed ~2704 bytes — so an over-long endpoint is a RAISED
    # Postgres 54000, not a truncation, i.e. a 500 from an ordinary POST.
    # Nothing downstream bounds it: the value is whatever a browser's
    # `PushManager` handed the page. Reproducing it needs INCOMPRESSIBLE data,
    # because Postgres compresses the index entry before testing it — a padded
    # probe of the same length fits and proves nothing.
    test "refuses an endpoint too long for its own unique index", %{conn: conn, user: user} do
      long = "https://push.example.com/" <> Base.url_encode64(:crypto.strong_rand_bytes(2400))

      conn = post(conn, ~p"/settings/push_devices", subscription_json(long))

      assert json_response(conn, 422)["ok"] == false
      assert Subscriptions.for_user(user.id) == []
    end

    test "refuses a body that is not a subscription", %{conn: conn, user: user} do
      conn = post(conn, ~p"/settings/push_devices", %{"endpoint" => @endpoint_url})

      assert json_response(conn, 422)["ok"] == false
      assert Subscriptions.for_user(user.id) == []
    end

    # An intranet installation reaches no push service, so it says so rather
    # than storing a subscription nothing would ever be sent to.
    test "answers 403 where the operator switched push off", %{conn: conn, user: user} do
      put_config(:web_push_enabled, false)

      conn = post(conn, ~p"/settings/push_devices", subscription_json())

      assert json_response(conn, 403)["error"] == "disabled"
      assert Subscriptions.for_user(user.id) == []
    end

    test "is not open to a logged-out visitor" do
      conn = post(build_conn(), ~p"/settings/push_devices", subscription_json())

      assert redirected_to(conn) == "/"
      assert Vutuv.Repo.aggregate(Subscription, :count) == 0
    end
  end

  describe "DELETE /settings/push_devices" do
    test "forgets the endpoint the browser names", %{conn: conn, user: user} do
      post(conn, ~p"/settings/push_devices", subscription_json())

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/settings/push_devices", %{"endpoint" => @endpoint_url})

      assert json_response(conn, 200) == %{"ok" => true}
      assert Subscriptions.for_user(user.id) == []
    end
  end

  describe "DELETE /settings/push_devices/:id" do
    test "forgets one of my own devices from the settings list", %{conn: conn, user: user} do
      post(conn, ~p"/settings/push_devices", subscription_json())
      [subscription] = Subscriptions.for_user(user.id)

      conn = conn |> recycle() |> delete(~p"/settings/push_devices/#{subscription.id}")

      assert redirected_to(conn) == ~p"/settings/notifications"
      assert Subscriptions.for_user(user.id) == []
    end

    # Scoped to the member, unlike the endpoint-named delete above: an id is
    # guessable in a way an endpoint is not, and this is the one door a member
    # reaches without already holding the browser's own address.
    test "leaves somebody else's device alone", %{conn: conn} do
      {other_conn, other} = login_second_user("other")
      post(other_conn, ~p"/settings/push_devices", subscription_json())
      [theirs] = Subscriptions.for_user(other.id)

      conn = delete(conn, ~p"/settings/push_devices/#{theirs.id}")

      assert redirected_to(conn) == ~p"/settings/notifications"
      assert [_still_there] = Subscriptions.for_user(other.id)
    end
  end
end
