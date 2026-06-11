defmodule VutuvWeb.WebhookControllerTest do
  @moduledoc """
  The bounce ingestion endpoint production Postfix pipes the bounce mailbox
  into (see scripts/postfix/). Raw RFC 822 body, bearer-token auth from
  `config :vutuv, :bounce_webhook_token`; without a configured token the
  endpoint plays dead (404).
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.Email
  alias Vutuv.Repo

  @token Application.compile_env!(:vutuv, :bounce_webhook_token)

  @failed_dsn """
  From: MAILER-DAEMON@mail.example.com (Mail Delivery System)
  Subject: Undelivered Mail Returned to Sender
  Content-Type: multipart/report; report-type=delivery-status; boundary="ABC"

  --ABC
  Content-Type: message/delivery-status

  Final-Recipient: rfc822; dead@example.com
  Action: failed
  Status: 5.1.1
  Diagnostic-Code: smtp; 550 5.1.1 User unknown

  --ABC--
  """

  defp post_dsn(conn, body, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "message/rfc822")
    |> post(~p"/webhooks/bounces", body)
  end

  test "a valid DSN with the right token marks the address undeliverable", %{conn: conn} do
    user = insert(:activated_user)
    insert(:email, user: user, value: "dead@example.com")

    conn = post_dsn(conn, @failed_dsn, @token)

    assert response(conn, 200)
    assert Repo.get_by!(Email, value: "dead@example.com").undeliverable_at
  end

  test "a wrong token is rejected and nothing is recorded", %{conn: conn} do
    user = insert(:activated_user)
    insert(:email, user: user, value: "dead@example.com")

    conn = post_dsn(conn, @failed_dsn, "wrong-token")

    assert response(conn, 401)
    assert Repo.get_by!(Email, value: "dead@example.com").undeliverable_at == nil
  end

  test "a missing Authorization header is rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "message/rfc822")
      |> post(~p"/webhooks/bounces", @failed_dsn)

    assert response(conn, 401)
  end

  test "an unparseable body is acknowledged as such", %{conn: conn} do
    conn = post_dsn(conn, "this is not a DSN at all", @token)

    assert response(conn, 422)
  end

  test "without a configured token the endpoint does not exist", %{conn: conn} do
    original = Application.get_env(:vutuv, :bounce_webhook_token)
    Application.put_env(:vutuv, :bounce_webhook_token, nil)
    on_exit(fn -> Application.put_env(:vutuv, :bounce_webhook_token, original) end)

    conn = post_dsn(conn, @failed_dsn, @token)

    assert response(conn, 404)
  end
end
