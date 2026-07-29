defmodule VutuvWeb.UsernameConfirmationTest do
  use VutuvWeb.ConnCase, async: false

  @moduledoc """
  Issue #1086: a rename is re-confirmed before it happens.

  Until this shipped, a live session was the only thing between a borrowed
  laptop and a public-identity change that frees the old handle for anyone to
  claim — while adding an email and deleting the account, its neighbours on the
  settings menu, both ask for a PIN. Step 1 now only validates and remembers the
  new handle; step 2 takes a passkey, an authenticator/list code, or a PIN
  emailed to one of the member's **own** addresses.

  `async: false`: the PIN attempt counters and the rate limiter are process- and
  ETS-backed state the SQL sandbox does not roll back.
  """

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Accounts.{LoginPin, User}
  alias Vutuv.LoginCodes

  # Step 1 of a rename, from a logged-in conn. Returns the conn showing the
  # confirmation page.
  defp start_rename(conn, handle \\ "brand_new") do
    post(conn, ~p"/settings/username", user: %{"username" => handle})
  end

  defp totp_user(user) do
    {:ok, pending} = LoginCodes.start_totp_enrollment(user)
    {:ok, _} = LoginCodes.confirm_totp(user, NimbleTOTP.verification_code(pending.secret))

    # The confirm stamped the current 30s window as used; backdate it so a fresh
    # code works without waiting a real window out.
    LoginCodes.get_totp(user)
    |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(:second), -120))
    |> Repo.update!()

    pending.secret
  end

  describe "step 1 no longer renames" do
    test "a valid handle advances to the confirmation instead of committing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      old_handle = user.username

      conn = start_rename(conn)

      html = html_response(conn, 200)
      # The page states plainly what is about to happen, both handles visible.
      assert html =~ "@brand_new"
      assert html =~ "@#{old_handle}"
      assert html =~ "_csrf_token"

      # Nothing has changed yet, and the old address still works.
      assert Repo.get(User, user.id).username == old_handle
    end

    test "the page leads with the fact that nothing has changed yet", %{conn: conn} do
      # The page used to present the rename as done: an h1 calling the pending
      # handle "your new username", and the old one struck through above a
      # section headed "What will change". Strikethrough is the universal "this
      # is gone" mark, so at a glance the member read the rename as finished and
      # the PIN as paperwork — reported by Stefan against his own account, which
      # is exactly how a confirmation step gets ignored.
      {conn, user} = create_and_login_user(conn)

      html = conn |> start_rename() |> html_response(200)

      # The reassurance is on the page, before any of the consequence prose, and
      # it names the handle the member still holds AND the factor that will
      # actually commit the rename — this member has only email, so: the PIN.
      assert html =~ "Nothing has changed yet"
      assert html =~ "You are still @#{user.username}"
      assert html =~ "once you confirm with the PIN below"

      # Both states are labelled, so neither chip has to be read as a diff.
      assert html =~ "Before and after"
      assert html =~ "Now"
      assert html =~ "After you confirm"

      assert Repo.get(User, user.id).username == user.username
    end

    test "the handle the member still holds is never struck through", %{conn: conn} do
      # `line-through` on the current handle is what said "already gone". Its
      # absence is the load-bearing part of the fix, so assert it directly —
      # a future restyle that reinstates the strikethrough must fail here.
      {conn, _user} = create_and_login_user(conn)

      html = conn |> start_rename() |> html_response(200)

      refute html =~ "line-through"
    end

    test "the heading does not call the pending handle the member's username", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> start_rename() |> html_response(200)

      assert html =~ "Change your username?"
      refute html =~ "Confirm your new username"
    end

    test "an invalid handle never reaches the confirmation and mails nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      flush_emails()

      conn = start_rename(conn, "not valid!")

      assert html_response(conn, 422) =~ "may only contain letters, numbers, and underscores"
      assert Repo.get(User, user.id).username == user.username
      # The whole point of validating first: no PIN chase for a name that was
      # never going to be accepted.
      refute_received {:email, _}
    end

    test "a handle taken by someone else is refused before any PIN goes out", %{conn: conn} do
      insert(:user, username: "wanted_handle")
      {conn, _user} = create_and_login_user(conn)
      flush_emails()

      conn = start_rename(conn, "wanted_handle")

      assert html_response(conn, 422) =~ "has already been taken"
      refute_received {:email, _}
    end
  end

  describe "the email PIN (the floor everybody has)" do
    test "where the PIN went is a notice above the field, rendered once", %{conn: conn} do
      # "We sent a PIN to <address>" is the instruction on this card, not a
      # caption. It lived under the input as the muted `.editform__hint` and then
      # as a semibold line in the same spot; Stefan reported it as buried both
      # times, because anything below the input is read as a footnote on the way
      # to the button. It is now `#pin-sent-notice` ABOVE the field — and the
      # hint copy under the field is dropped in that state, so the same sentence
      # can never appear twice.
      {conn, user} = create_and_login_user(conn)
      email = Accounts.first_email_value(user)

      html = conn |> start_rename() |> html_response(200)

      assert html =~ ~s(id="pin-sent-notice")
      assert html =~ email

      occurrences = html |> String.split("We sent a PIN to") |> length() |> Kernel.-(1)
      assert occurrences == 1

      # The notice sits before the input in the document, which is what makes it
      # read as a step rather than a caption.
      [before_field, _] = String.split(html, ~s(name="username_confirmation[code]"), parts: 2)
      assert before_field =~ "pin-sent-notice"
    end

    test "with no PIN in flight there is no sent-notice, just the field hint", %{conn: conn} do
      # A member with an authenticator app is deliberately not mailed unasked, so
      # claiming we sent one would send them to an empty inbox.
      {conn, user} = create_and_login_user(conn)
      totp_user(user)

      html = conn |> start_rename() |> html_response(200)

      refute html =~ ~s(id="pin-sent-notice")
      refute html =~ "We sent a PIN to"
      assert html =~ "editform__hint"
    end

    test "one address and no other factor: the PIN is already on its way", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      email = Accounts.first_email_value(user)
      flush_emails()

      conn = start_rename(conn)
      html = html_response(conn, 200)

      # No choice to make, so the page just says where to look.
      assert html =~ email
      pin = sent_pin()

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "@brand_new"
    end

    test "the PIN names the handle it authorizes", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      flush_emails()

      start_rename(conn, "renamed_soon")

      assert_received {:email, email}
      assert email.subject =~ "username"
      assert email.text_body =~ "@renamed_soon"
      # An unasked-for PIN has to read as an alarm, not as noise.
      assert email.text_body =~ "did not ask"
    end

    test "a wrong PIN keeps the pending change so the member can retry", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()
      wrong = if pin == "000000", do: "000001", else: "000000"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => wrong}
        })

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Incorrect"
      assert Repo.get(User, user.id).username == user.username

      # The pending handle survived, so the right PIN still finishes the job.
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")
      assert html_response(conn, 200) =~ "@brand_new"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
    end

    test "a spent PIN cannot be replayed into a second rename", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()

      first =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(first) == ~p"/brand_new"

      # Re-submitting the consumed PIN (a double-tap, a back-navigation) must not
      # rename anything again; the pending change went with the first success.
      second =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(second) == ~p"/settings/username"
      assert Repo.get(User, user.id).username == "brand_new"
    end
  end

  describe "choosing which address gets the PIN" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:email,
        value: "second-#{System.unique_integer([:positive])}@example.com",
        user: user
      )

      flush_emails()

      %{conn: conn, user: user}
    end

    test "with several addresses nothing is mailed until one is picked", %{
      conn: conn,
      user: user
    } do
      conn = start_rename(conn)
      html = html_response(conn, 200)

      # Every address the member owns is offered, and none of them was mailed
      # behind their back.
      for value <- Accounts.list_email_values(user), do: assert(html =~ value)
      assert html =~ "username_pin[email]"
      refute_received {:email, _}
    end

    test "the page never claims a PIN was mailed when none was", %{conn: conn} do
      # Caught in the browser: the code field's hint read "enter the PIN we
      # emailed you" on a page that had deliberately mailed nothing, which sends
      # the member hunting through an inbox for a mail that does not exist.
      html = conn |> start_rename() |> html_response(200)

      refute html =~ "We sent a PIN"
      assert html =~ "Ask for a PIN first"
      # And the way to get one is above the field, not stranded under the submit.
      assert html =~ ~r/username-pin-form.*username-confirm-form/s
    end

    test "the PIN goes to the address the member picked", %{conn: conn, user: user} do
      [_first, second] = Accounts.list_email_values(user)
      conn = start_rename(conn)

      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => second}
        })

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ second

      assert_received {:email, mail}
      assert {_name, ^second} = mail.to |> List.first()
    end

    test "an address the member does not own is refused, and mails nobody", %{conn: conn} do
      conn = start_rename(conn)

      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => "attacker@example.com"}
        })

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "your own email"
      # The real bug this guards: the picker must not be a relay that mails a
      # valid PIN to an address chosen by whoever holds the session.
      refute_received {:email, _}
    end

    test "the PIN mailed to the second address confirms the rename", %{conn: conn, user: user} do
      [_first, second] = Accounts.list_email_values(user)
      conn = start_rename(conn)

      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => second}
        })

      pin = sent_pin()
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end
  end

  describe "authenticator app and one-time codes" do
    test "a member with an authenticator app is not mailed a PIN unasked", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      secret = totp_user(user)
      flush_emails()

      conn = start_rename(conn)
      html = html_response(conn, 200)

      # They have a faster way in, so mailing anyway would train them to ignore
      # exactly the mail that is meant to alarm them.
      refute_received {:email, _}
      assert html =~ "authenticator app"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end

    test "a member with an authenticator app is not told to confirm with a PIN", %{conn: conn} do
      # The notice names the PIN only when an emailed PIN is the member's only
      # way in. Telling a member holding an authenticator app to "confirm with
      # the PIN below" would send them hunting for mail we deliberately never
      # sent (`start_confirmation` mails nothing to a member with a faster
      # factor), which is the same untrue-page failure the notice exists to fix.
      {conn, user} = create_and_login_user(conn)
      totp_user(user)

      html = conn |> start_rename() |> html_response(200)

      assert html =~ "Nothing has changed yet"
      assert html =~ "once you confirm below"
      refute html =~ "once you confirm with the PIN below"
    end

    test "a one-time list code confirms the rename too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      [code | _] = LoginCodes.generate_list_codes(user)
      flush_emails()

      conn = start_rename(conn)
      refute_received {:email, _}

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => code.code}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end

    test "an alternate code spends a PIN that was mailed alongside it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      secret = totp_user(user)
      conn = start_rename(conn)

      # The member asked for a PIN as well, then used their app instead. The PIN
      # left in the inbox must not stay live.
      conn =
        submit_with_csrf(conn, ~p"/settings/username/pin", %{
          "username_pin" => %{"email" => Accounts.first_email_value(user)}
        })

      _pin = sent_pin()
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => NimbleTOTP.verification_code(secret)}
        })

      assert redirected_to(conn) == ~p"/brand_new"

      row = Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == "username"))
      assert row.consumed_at
    end
  end

  describe "passkey confirmation" do
    test "the card's opening line names the passkey instead of pointing at the field", %{
      conn: conn
    } do
      # Every other factor is typed into the code field, so "enter a valid code
      # below" is true for almost everyone — but a passkey is a button and
      # nothing is typed, so that wording sends a passkey holder looking for a
      # field they never have to touch.
      {conn, user} = create_and_login_user(conn)

      conn = start_rename(conn)
      assert html_response(conn, 200) =~ "It changes only once you enter a valid code below"

      insert(:user_credential, user: user)
      html = conn |> recycle() |> get(~p"/settings/username/confirm") |> html_response(200)

      assert html =~ "confirm with your passkey or a valid code below"
      refute html =~ "It changes only once you enter a valid code below"
    end

    test "the button is offered only to members who enrolled one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = start_rename(conn)
      refute html_response(conn, 200) =~ "data-webauthn-confirm"

      insert(:user_credential, user: user)
      conn = conn |> recycle() |> get(~p"/settings/username/confirm")
      html = html_response(conn, 200)

      assert html =~ "data-webauthn-confirm"
      assert html =~ ~s(data-challenge-url="#{~p"/settings/username/passkey/challenge"}")
      # Verifying stamps the session; the JS then submits the ordinary form, so
      # the rename keeps one CSRF-protected commit path.
      assert html =~ ~s(data-submit-form="username-passkey-form")
    end

    test "the challenge endpoint answers JSON and stores the challenge", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      conn = start_rename(conn)

      conn = conn |> recycle() |> post(~p"/settings/username/passkey/challenge")

      assert %{"rpId" => "localhost"} = json_response(conn, 200)
      assert %Wax.Challenge{} = get_session(conn, :username_change_challenge)
    end

    test "a bogus assertion renames nobody", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      conn = conn |> recycle() |> post(~p"/settings/username/passkey/challenge")

      conn =
        conn
        |> recycle()
        |> post(~p"/settings/username/passkey", %{
          "rawId" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          "authenticatorData" => Base.url_encode64("authdata", padding: false),
          "signature" => Base.url_encode64("signature", padding: false),
          "clientDataJSON" => Base.url_encode64("{}", padding: false)
        })

      assert %{"ok" => false} = json_response(conn, 422)
      refute get_session(conn, :username_change_passkey_at)
      assert Repo.get(User, user.id).username == user.username
    end

    test "a completed ceremony confirms without any code", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)

      # Stand in for the browser ceremony (it cannot run in the test adapter):
      # this is the session stamp passkey_verify/2 leaves behind on success.
      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          username_change: "brand_new",
          username_change_at: System.system_time(:second),
          username_change_passkey_at: System.system_time(:second)
        })

      conn =
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/settings/username/confirm", %{})

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
      # One rename per ceremony: the stamp is spent with the change.
      refute get_session(conn, :username_change_passkey_at)
    end

    test "a stale ceremony no longer confirms", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          username_change: "brand_new",
          username_change_at: System.system_time(:second),
          # Older than the 10-minute window: whoever sits down at the abandoned
          # laptop must not be able to finish it.
          username_change_passkey_at: System.system_time(:second) - 3_600
        })

      conn =
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/settings/username/confirm", %{})

      assert redirected_to(conn) == ~p"/settings/username/confirm"
      assert Repo.get(User, user.id).username == user.username
    end
  end

  describe "German" do
    test "the confirmation page is German for a German visitor", %{conn: conn} do
      # vutuv is a German site, so an untranslated new page is an English island
      # in the middle of the settings area — and a plain English test never sees
      # it. Assert the German render of the strings this page introduced.
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> post(~p"/settings/username", user: %{"username" => "neuer_name"})
        |> html_response(200)

      assert html =~ "Noch hat sich nichts geändert"
      assert html =~ "Sie sind weiterhin @"
      assert html =~ "Vorher und nachher"
      assert html =~ "Bestätigen Sie, dass Sie es sind"
      assert html =~ "Benutzernamen jetzt ändern"
      refute html =~ "Nothing has changed yet"

      # The two state labels, asserted by name. `mix gettext.extract --merge`
      # fuzzy-matched these against unrelated existing entries when they were
      # added and produced real nonsense: "Now" came out as "Nein" (No), "Not
      # yours yet." as "Noch keine Reposts." Fuzzy entries carry a flag but no
      # build failure, so only an assertion on the rendered German catches a
      # re-merge doing it again.
      assert html =~ "Jetzt"
      assert html =~ "Nach der Bestätigung"
      assert html =~ "Gehört Ihnen noch nicht."
      refute html =~ "Nein"
      refute html =~ "Noch keine Reposts"

      # The notice names the factor, not just "confirm below" (Stefan, on the
      # rendered page): this member has only email, so it is the PIN.
      assert html =~ "unten per PIN bestätigen"
    end

    test "the PIN email is German for a German member", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user |> Ecto.Changeset.change(locale: "de") |> Repo.update!()
      flush_emails()

      start_rename(conn)

      assert_received {:email, mail}
      assert mail.subject =~ "Benutzernamen"
      assert mail.text_body =~ "Der PIN verfällt"
    end
  end

  describe "a confirmation with nothing pending" do
    test "the page sends the member back to the form", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      assert conn |> get(~p"/settings/username/confirm") |> redirected_to() ==
               ~p"/settings/username"
    end

    test "submitting a code renames nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/settings/username")

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => "123456"}
        })

      assert redirected_to(conn) == ~p"/settings/username"
      assert Repo.get(User, user.id).username == user.username
    end

    test "going back to the form does not destroy the confirmation", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()

      # A GET must be safe. This URL is reached by accident constantly — the
      # sidebar row, the breadcrumb, the Back button, a link prefetch — and
      # clearing the pending rename here made any of those answer the member's
      # correct PIN with "this confirmation expired" (found in a browser smoke
      # test, with nothing on screen to explain it).
      conn = conn |> recycle() |> get(~p"/settings/username")
      assert html_response(conn, 200) =~ ~s(id="slug-form")

      conn = conn |> recycle() |> get(~p"/settings/username/confirm")
      assert html_response(conn, 200) =~ "@brand_new"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => pin}
        })

      assert redirected_to(conn) == ~p"/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"
    end

    test "a confirmation left for half an hour goes stale", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = start_rename(conn)
      pin = sent_pin()

      # Keeping the pending change across GETs must not mean keeping it forever:
      # it ages out with the PIN that confirms it.
      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          username_change: "brand_new",
          username_change_at: System.system_time(:second) - 3_600
        })

      conn =
        conn
        |> put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/settings/username/confirm", %{"username_confirmation" => %{"code" => pin}})

      assert redirected_to(conn) == ~p"/settings/username"
      assert Repo.get(User, user.id).username == user.username
    end

    test "guests cannot reach any step of the confirmation", %{conn: conn} do
      assert conn |> get(~p"/settings/username/confirm") |> redirected_to() == "/"
      assert conn |> post(~p"/settings/username/confirm") |> redirected_to() == "/"
      assert conn |> post(~p"/settings/username/pin") |> redirected_to() == "/"
      assert conn |> post(~p"/settings/username/passkey/challenge") |> redirected_to() == "/"
    end
  end
end
