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
    test "every message leaves with the bounce address as envelope sender" do
      # The Swoosh SMTP adapter uses the Sender header as SMTP MAIL FROM, so
      # bounces (DSNs) all come back to the one piped bounce mailbox instead
      # of info@. The From stays untouched.
      email = Emailer.base_email()
      assert email.headers["Sender"] == "bounces@vutuv.de"
      assert email.from == {"vutuv", "info@vutuv.de"}

      raw =
        Swoosh.Email.new()
        |> Swoosh.Email.from({"vutuv", "info@vutuv.de"})
        |> Swoosh.Email.to("nobody@example.com")
        |> Swoosh.Email.subject("Naked email")
        |> Swoosh.Email.text_body("hi")

      Emailer.deliver(raw)
      assert_email_sent(fn sent -> assert sent.headers["Sender"] == "bounces@vutuv.de" end)
    end

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
    test "registration email (unactivated user)" do
      user = insert(:user, activated?: false, locale: "en")

      @pin
      |> Emailer.login_email("reg@example.com", user)
      |> assert_robot_headers()
    end

    test "login email (activated user)" do
      user = insert(:user, activated?: true, locale: "en")

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

    test "unread messages email" do
      user = insert(:user, locale: "en")
      other = insert(:user, active_slug: "the-sender")

      email =
        Emailer.unread_messages_email("unread@example.com", user, other, Vutuv.UUIDv7.generate())

      assert_robot_headers(email)
      # System text names accounts by their @handle, never the clear name.
      assert email.subject =~ "@the-sender"
      assert email.text_body =~ "@the-sender"
      refute email.text_body =~ other.first_name
    end
  end

  describe "notification mail carries the one-click unsubscribe (RFC 8058)" do
    test "the unread-message email has the headers and the footer link" do
      user = insert(:activated_user, locale: "en")
      other = insert(:user)

      email =
        Emailer.unread_messages_email("unread@example.com", user, other, Vutuv.UUIDv7.generate())

      assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      assert email.headers["List-Unsubscribe"] =~ "/unsubscribe/"
      assert email.headers["List-Unsubscribe"] =~ "mailto:"
      assert email.text_body =~ "/unsubscribe/"

      # The link in the mail really authorizes that recipient, nobody else.
      [_, token] = Regex.run(~r{/unsubscribe/([\w._-]+)}, email.text_body)
      assert {:ok, user_id} = VutuvWeb.UnsubscribeToken.verify(token)
      assert user_id == user.id
    end

    test "transactional PIN mail carries no unsubscribe headers" do
      user = insert(:user, activated?: false, locale: "en")
      email = Emailer.login_email(@pin, "reg@example.com", user)

      assert email.headers["List-Unsubscribe"] == nil
      assert email.headers["List-Unsubscribe-Post"] == nil
    end
  end

  describe "PIN emails name a PIN, never a link (issue #759)" do
    # These four emails carry a 6-digit PIN. The German subjects used to say
    # "Login-Link" / "Link zum Löschen ...", which sent recipients hunting for a
    # link that is not there. Subject and body both follow the recipient's
    # locale, so each is checked under both locales.

    test "every PIN email carries the PIN and mentions no link, in en and de" do
      builders = [
        {"login",
         fn loc ->
           Emailer.login_email(
             @pin,
             "u@example.com",
             insert(:user, activated?: true, locale: loc)
           )
         end},
        {"registration",
         fn loc ->
           Emailer.login_email(
             @pin,
             "u@example.com",
             insert(:user, activated?: false, locale: loc)
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
      user = insert(:user, activated?: true, locale: "de")

      assert Emailer.login_email(@pin, "login@example.com", user).subject == "vutuv Login-PIN"
    end
  end

  describe "emails follow the recipient's locale, not the sender's" do
    # The subject used to render in the ambient process locale — the locale of
    # whoever triggered the send (e.g. an admin verifying another member) —
    # while the body template came from the recipient's stored locale.

    test "a German recipient gets a German subject from an English sender" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      user = insert(:user, activated?: true, locale: "de")

      assert Emailer.login_email(@pin, "login@example.com", user).subject == "vutuv Login-PIN"
    end

    test "the English verification notice is English throughout (incl. the signature)" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      user = insert(:user, locale: "en")
      insert(:email, user: user, value: "verify@example.com")

      email = Emailer.verification_notice(user)

      assert email.subject == "vutuv Account verified"
      # Regression: the EN template used to render the German signature partial.
      assert email.text_body =~ "Regards"
      refute email.text_body =~ "Mit freundlichen Grüßen"
    end
  end

  describe "emails link the configured host, not hardcoded legacy URLs" do
    # public_url is "http://localhost:4000/" in the test env. The templates
    # used to hardcode https://vutuv.de plus the legacy /users/<slug> and
    # /sessions/new paths, which only still work via 301 redirects.

    test "the verification notice links the recipient's profile at the root path" do
      user = insert(:user, locale: "en", active_slug: "verified-user")
      insert(:email, user: user, value: "verify@example.com")

      body = Emailer.verification_notice(user).text_body

      assert body =~ "http://localhost:4000/verified-user"
      refute body =~ "vutuv.de/users/"
    end

    test "the login email points PIN renewal at the configured login URL" do
      user = insert(:user, activated?: true, locale: "en")

      body = Emailer.login_email(@pin, "login@example.com", user).text_body

      assert body =~ "http://localhost:4000/login"
      refute body =~ "vutuv.de/sessions/new"
    end
  end
end
