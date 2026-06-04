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
  end

  describe "PIN emails name a PIN, never a link (issue #759)" do
    # These four emails carry a 6-digit PIN. The German subjects used to say
    # "Login-Link" / "Link zum Löschen ...", which sent recipients hunting for a
    # link that is not there. The subject is rendered with the ambient Gettext
    # locale and the body from the user's locale, so each is checked under both.

    test "every PIN email carries the PIN and mentions no link, in en and de" do
      builders = [
        {"login",
         fn loc ->
           Emailer.login_email(
             @pin,
             "u@example.com",
             insert(:user, validated?: true, locale: loc)
           )
         end},
        {"registration",
         fn loc ->
           Emailer.login_email(
             @pin,
             "u@example.com",
             insert(:user, validated?: false, locale: loc)
           )
         end},
        {"email creation",
         fn loc ->
           Emailer.email_creation_email(@pin, "new@example.com", insert(:user, locale: loc))
         end},
        {"account deletion",
         fn loc ->
           Emailer.user_deletion_email(@pin, "u@example.com", insert(:user, locale: loc))
         end}
      ]

      for {label, build} <- builders, locale <- ~w(en de) do
        Gettext.put_locale(VutuvWeb.Gettext, locale)
        email = build.(locale)

        assert email.text_body =~ @pin,
               "the #{label} email (#{locale}) should print the PIN in its body"

        refute email.subject =~ ~r/link/i,
               "the #{label} email (#{locale}) subject must not mention a link, got: #{email.subject}"

        refute email.text_body =~ ~r/link/i,
               "the #{label} email (#{locale}) body must not mention a link"
      end
    end

    test "the German login subject names a PIN, not a link" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      user = insert(:user, validated?: true, locale: "de")

      assert Emailer.login_email(@pin, "login@example.com", user).subject == "vutuv Login-PIN"
    end
  end
end
