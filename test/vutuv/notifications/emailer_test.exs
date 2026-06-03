defmodule Vutuv.Notifications.EmailerTest do
  @moduledoc """
  Every outbound vutuv email is machine-generated, so every message must carry
  the auto-generated robot headers (issue #763). These tests assert the headers
  are present on at least one message of every type and that the single
  `deliver/1` chokepoint re-applies them.
  """
  use Vutuv.DataCase, async: false
  import Swoosh.TestAssertions

  alias Vutuv.Notifications.Emailer

  @pin "123456"

  defp assert_robot_headers(email) do
    assert email.headers["Auto-Submitted"] == "auto-generated"
    assert email.headers["X-Auto-Response-Suppress"] == "All"
    email
  end

  describe "base_email/0 and headers" do
    test "base_email carries the From and the robot headers" do
      email = Emailer.base_email()

      assert email.from == {"vutuv", "info@vutuv.de"}
      assert_robot_headers(email)
    end

    test "bulk_headers/1 adds the opt-in bulk headers" do
      email = Emailer.base_email() |> Emailer.bulk_headers()

      assert email.headers["Precedence"] == "bulk"
      assert email.headers["List-Unsubscribe"] =~ "mailto:"
    end
  end

  describe "deliver/1 chokepoint" do
    test "re-applies the robot headers even when a builder forgot the base" do
      raw =
        Swoosh.Email.new()
        |> Swoosh.Email.from({"vutuv", "info@vutuv.de"})
        |> Swoosh.Email.to("nobody@example.com")
        |> Swoosh.Email.subject("Naked email")
        |> Swoosh.Email.text_body("hi")

      assert raw.headers["Auto-Submitted"] == nil

      Emailer.deliver(raw)

      assert_email_sent(fn email -> assert_robot_headers(email) end)
    end
  end

  describe "transactional builders carry the robot headers" do
    test "registration email (unvalidated user)" do
      user = insert(:user, validated?: false, locale: "en")

      @pin
      |> Emailer.login_email("reg@example.com", user)
      |> assert_robot_headers()
    end

    test "login email (validated user)" do
      user = insert(:user, validated?: true, locale: "en")

      @pin
      |> Emailer.login_email("login@example.com", user)
      |> assert_robot_headers()
    end

    test "email creation email" do
      user = insert(:user, locale: "en")

      @pin
      |> Emailer.email_creation_email("newaddress@example.com", user)
      |> assert_robot_headers()
    end

    test "user deletion email" do
      user = insert(:user, locale: "en")

      @pin
      |> Emailer.user_deletion_email("delete@example.com", user)
      |> assert_robot_headers()
    end

    test "verification notice" do
      user = insert(:user, locale: "en")
      insert(:email, user: user, value: "verify@example.com")

      user
      |> Emailer.verification_notice()
      |> assert_robot_headers()
    end

    test "payment information email" do
      user = insert(:user, locale: "en")
      package = insert(:recruiter_package)
      subscription = insert(:recruiter_subscription, user: user, recruiter_package: package)

      subscription
      |> Emailer.payment_information_email(user, "pay@example.com")
      |> assert_robot_headers()
    end

    test "invoice email" do
      with_accounting_email("accounting@vutuv.de", fn ->
        user = insert(:user, locale: "en")
        package = insert(:recruiter_package)
        subscription = insert(:recruiter_subscription, user: user, recruiter_package: package)

        subscription
        |> Emailer.issue_invoice(user, "accounting@vutuv.de")
        |> assert_robot_headers()
      end)
    end
  end

  describe "bulk builders carry both robot and bulk headers" do
    test "birthday reminder" do
      user = insert(:user, locale: "en")
      insert(:email, user: user, value: "birthday@example.com")
      child = insert(:user, birthdate: ~D[1990-01-01])

      email = Emailer.birthday_reminder(user, [child], [])

      assert_robot_headers(email)
      assert email.headers["Precedence"] == "bulk"
    end
  end

  # Temporarily set the accounting email in the endpoint config so the
  # invoice builder produces a message, then restore the previous config.
  defp with_accounting_email(value, fun) do
    config = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)

    Application.put_env(
      :vutuv,
      VutuvWeb.Endpoint,
      Keyword.put(config, :accounting_email, value)
    )

    try do
      fun.()
    after
      Application.put_env(:vutuv, VutuvWeb.Endpoint, config)
    end
  end
end
