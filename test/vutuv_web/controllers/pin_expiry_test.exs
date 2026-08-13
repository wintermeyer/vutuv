defmodule VutuvWeb.PinExpiryTest do
  @moduledoc """
  What the sign-up PIN screen says about the PIN running out.

  It used to say nothing at all. A PIN is good for 30 minutes, so somebody who
  put the tab aside and came back met a form that simply refused the number in
  their inbox, with no word about why — and no word about the half-finished
  account the sweeper was by then about to delete under them. The three claims
  the page now makes are all tied to constants rather than to numbers typed into
  a translation, and this file is what keeps them tied.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts

  # `registration_attrs/1` (ConnCase) mints a fresh address, name and handle per
  # call and uses this module's own tag set: a hand-built literal would put every
  # run on the same email / username / tag rows, which is the documented 40P01
  # deadlock between async modules inside one `register_user` transaction.
  defp pin_screen(conn, headers \\ []) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    conn
    |> post(~p"/new_registration", user: registration_attrs("expiry"))
    |> html_response(200)
  end

  defp german_pin_screen(conn) do
    pin_screen(conn, [{"accept-language", "de-DE,de;q=0.9"}])
  end

  defp seconds_left(body) do
    [_, value] = Regex.run(~r/data-pin-seconds-left="(\d+)"/, body)
    String.to_integer(value)
  end

  describe "the screen says how long the PIN is good for" do
    test "in English", %{conn: conn} do
      assert pin_screen(conn) =~
               "The PIN is valid for #{Accounts.pin_validity_minutes()} more minutes."
    end

    # A German-only render is not a formality here: every one of these strings is
    # brand new, and `gettext.extract --merge` fills a new msgid with the
    # translation of whatever it looks similar to rather than leaving it empty.
    test "in German", %{conn: conn} do
      assert german_pin_screen(conn) =~
               "Die PIN ist noch #{Accounts.pin_validity_minutes()} Minuten gültig."
    end

    test "the browser gets the sentences it needs to count down in", %{conn: conn} do
      body = german_pin_screen(conn)

      # The four plural forms ride the element because the server is the only
      # side that knows the reader's language. Losing them would leave a
      # countdown that ticks in English on a German page.
      assert body =~ "Die PIN ist noch eine Minute gültig."
      assert body =~ "Die PIN ist noch {n} Minuten gültig."
      assert body =~ "Die PIN ist noch eine Sekunde gültig."
      assert body =~ "Die PIN ist noch {n} Sekunden gültig."
    end
  end

  describe "the countdown is anchored to the PIN, not to the render" do
    test "the page carries the seconds the PIN really has left", %{conn: conn} do
      window = Accounts.pin_validity_minutes() * 60
      left = seconds_left(pin_screen(conn))

      assert left <= window
      assert left > window - 30
    end

    # Why the deadline rides the signed cookie instead of being computed per
    # render: "/" is pinned to this screen while a PIN is in flight, so it is
    # exactly the page a member reloads, and a per-render deadline would hand
    # them a fresh 30 minutes every time for a PIN that is quietly dying.
    #
    # Honest about its own reach: both renders land inside the same second, so
    # this cannot fail a naive per-render implementation. It documents the claim
    # and catches a reload that loses the deadline altogether (no attribute at
    # all makes `seconds_left/1` raise); the timing itself is not testable
    # without either sleeping or an injectable clock.
    test "reloading \"/\" does not hand out a fresh window", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: registration_attrs("expiry"))
      first = seconds_left(html_response(conn, 200))

      again = conn |> recycle() |> get(~p"/") |> html_response(200)

      assert seconds_left(again) <= first
    end
  end

  describe "the state the screen turns into when the PIN runs out" do
    test "ships rendered but hidden, with the live half showing", %{conn: conn} do
      body = pin_screen(conn)

      # Both halves are one server render, so a member with no JavaScript keeps a
      # working form and the plain validity sentence. Asserting the `hidden`
      # sits on the tag itself is deliberate: the panel must never ship visible,
      # and no display utility may join it there (the issue #880 trap).
      assert body =~ "<div data-pin-live>"
      assert body =~ "<div data-pin-expired hidden"
    end

    # The hero swaps with the card. It is the pair that made this worth testing:
    # "Please check your INBOX." left standing beside a card announcing the PIN
    # is dead is a page arguing with itself, and nothing about the card's own
    # markup would ever catch that.
    test "the hero has a state of its own, so it cannot contradict the card",
         %{conn: conn} do
      body = pin_screen(conn)

      assert body |> String.split("data-pin-live") |> length() == 3
      assert body |> String.split("data-pin-expired") |> length() == 3
      assert body =~ "Please check your INBOX."
      assert body =~ "The PIN has expired."
    end

    test "names the grace the sweeper leaves, and the way back", %{conn: conn} do
      body = pin_screen(conn)
      grace = Accounts.unconfirmed_registration_grace_minutes()

      assert body =~ "The PIN has expired."
      assert body =~ "we delete it automatically in about #{grace} minutes"
      assert body =~ "sign up again right away with the same email address"
      assert body =~ "Register again"
    end

    test "says all of it in German too", %{conn: conn} do
      body = german_pin_screen(conn)
      grace = Accounts.unconfirmed_registration_grace_minutes()

      assert body =~ "Die PIN ist abgelaufen."
      assert body =~ "löschen wir sie automatisch in rund #{grace} Minuten"
      assert body =~ "sofort mit derselben E-Mail-Adresse neu registrieren"
      assert body =~ "Neu registrieren"
    end
  end

  describe "submitting a PIN that has already expired" do
    # Not the login form. Somebody whose sign-up PIN ran out has no account to
    # sign in to, so the login page is the one page that cannot help them; "/"
    # is where a second go actually works, because an abandoned sign-up is
    # handed a fresh PIN when the same address comes back.
    test "sends a half-finished registration back to the sign-up form", %{conn: conn} do
      params = registration_attrs("expiry")
      conn = post(conn, ~p"/new_registration", user: params)
      pin = sent_pin()

      user = Accounts.get_user_by_handle_or_email(params["emails"]["0"]["value"])
      expire_pin(user)

      conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => pin}})

      assert redirected_to(conn) == ~p"/"
    end

    test "still sends an expired login back to the login form", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value

      conn = post(conn, ~p"/login", session: %{"email" => email})
      pin = sent_pin()
      expire_pin(user)

      conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => pin}})

      assert redirected_to(conn) == ~p"/login"
    end
  end

  # Age the PIN past its window without sleeping. `minted_at` is what
  # `Accounts.pin_expired?/1` judges by.
  defp expire_pin(user) do
    minted_at =
      NaiveDateTime.utc_now(:second)
      |> NaiveDateTime.add(-(Accounts.pin_validity_minutes() * 60 + 60))

    Vutuv.Repo.update_all(
      from(p in Vutuv.Accounts.LoginPin, where: p.user_id == ^user.id and p.type == "login"),
      set: [minted_at: minted_at]
    )
  end
end
