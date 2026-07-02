defmodule VutuvWeb.DevWebhookControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth
  alias Vutuv.Webhooks

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    {conn, user} = create_and_login_user(conn)

    {:ok, app, _secret} =
      ApiAuth.create_app(user, %{
        "name" => "Hook App",
        "redirect_uris" => ["https://app.example.org/cb"]
      })

    {:ok, conn: conn, user: user, app: app}
  end

  test "add a webhook, see the secret once, ping, delete", %{conn: conn, app: app} do
    conn =
      post(conn, ~p"/developers/apps/#{app.id}/webhooks",
        subscription: %{
          "url" => "https://hooks.example.org/vutuv",
          "events" => ["follower.created", "message.created"]
        }
      )

    assert redirected_to(conn) == "/developers/apps/#{app.id}"

    conn = get(conn, ~p"/developers/apps/#{app.id}")
    response = html_response(conn, 200)
    assert [_, _secret] = Regex.run(~r/(vutuv_whsec_[a-z2-7]+)/, response)
    assert response =~ "hooks.example.org"

    refute conn |> get(~p"/developers/apps/#{app.id}") |> html_response(200) =~ "vutuv_whsec_"

    [subscription] = Webhooks.list_subscriptions(app)

    conn = post(conn, ~p"/developers/apps/#{app.id}/webhooks/#{subscription.id}/ping")
    assert redirected_to(conn) == "/developers/apps/#{app.id}"
    assert [%{event: "ping"}] = Vutuv.Repo.all(Vutuv.Webhooks.Delivery)

    conn = delete(conn, ~p"/developers/apps/#{app.id}/webhooks/#{subscription.id}")
    assert redirected_to(conn) == "/developers/apps/#{app.id}"
    assert Webhooks.list_subscriptions(app) == []
  end

  test "invalid input re-renders the form", %{conn: conn, app: app} do
    conn =
      post(conn, ~p"/developers/apps/#{app.id}/webhooks",
        subscription: %{"url" => "ftp://nope", "events" => []}
      )

    assert html_response(conn, 422) =~ "editform"
  end

  test "webhooks are owner-scoped", %{app: app} do
    {:ok, subscription, _secret} =
      Webhooks.create_subscription(app, %{
        "url" => "https://hooks.example.org/x",
        "events" => ["follower.created"]
      })

    other_conn = build_conn() |> Plug.Test.init_test_session(%{})

    {other_conn, _other} =
      create_and_login_user(other_conn, %{
        "emails" => %{"0" => %{"value" => "intruder@example.com"}},
        "first_name" => "intruder"
      })

    assert get(other_conn, ~p"/developers/apps/#{app.id}/webhooks/new").status == 404

    assert delete(other_conn, ~p"/developers/apps/#{app.id}/webhooks/#{subscription.id}").status ==
             404

    assert [_still_there] = Webhooks.list_subscriptions(app)
  end
end
