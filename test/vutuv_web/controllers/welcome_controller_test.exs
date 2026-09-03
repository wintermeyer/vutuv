defmodule VutuvWeb.WelcomeControllerTest do
  @moduledoc """
  The one-time welcome questions: the location + job search a brand-new member
  is asked right after the registration PIN, in a **modal over their own
  profile** (`VutuvWeb.Plug.WelcomeModal` + the layout) that closes with the ✕.
  `/system/welcome` is the form's POST target and the frame a rejected submit
  falls back to.

  Three things worth guarding: the **laxness** (any single location field is a
  complete answer, and an empty form is not an error), the **once**
  (`welcome_completed_at` gates modal and page alike, so nobody is nagged on
  later logins) and that **closing is an answer** — the ✕ posts the same skip
  the button does, so the questions are visibly optional.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Address

  defp address_of(user), do: Repo.one(from(a in Address, where: a.user_id == ^user.id))

  defp reload(user), do: Repo.get!(User, user.id)

  # The only way onto the page: register, then confirm the PIN the way the
  # confirmation form does (context "registration"). That login is what opens
  # the one-shot URL; a plain login never does.
  defp register_and_confirm(conn) do
    n = System.unique_integer([:positive])

    attrs = %{
      "emails" => %{"0" => %{"value" => "welcome#{n}@example.com"}},
      "first_name" => "Welcome#{n}",
      "tag_list" => @registration_tags
    }

    conn = post(conn, ~p"/new_registration", user: attrs)
    pin = sent_pin()

    conn =
      submit_with_csrf(conn, ~p"/login", %{
        "session" => %{"pin" => pin, "context" => "registration"}
      })

    {conn, Repo.get!(User, Plug.Conn.get_session(conn, :user_id))}
  end

  describe "arriving from the registration PIN" do
    # The member is in — so the PIN hands them their own profile, and the
    # questions float over it. Landing on a form instead reads as a step of the
    # registration that still has to be got through.
    test "the confirming PIN lands on the profile, not on a form", %{conn: conn} do
      attrs = %{
        "emails" => %{"0" => %{"value" => "welcome-newcomer@example.com"}},
        "first_name" => "Newcomer",
        "tag_list" => @registration_tags
      }

      conn = post(conn, ~p"/new_registration", user: attrs)
      pin = sent_pin()

      conn =
        submit_with_csrf(conn, ~p"/login", %{
          "session" => %{"pin" => pin, "context" => "registration"}
        })

      user = Repo.get!(User, Plug.Conn.get_session(conn, :user_id))
      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "an ordinary login goes home, never to the welcome page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "a member who already left the page behind is sent to their profile", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)
      {:ok, _} = Accounts.complete_welcome(user)

      conn = get(conn, ~p"/system/welcome")

      assert redirected_to(conn) == ~p"/#{user}"
    end

    # The URL is one-shot: a member who never finished it still cannot open it
    # again from a bookmark or another session, because only the confirming
    # PIN opens it.
    test "a later visit is sent to the profile even with the page unfinished", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/system/welcome")

      assert redirected_to(conn) == ~p"/#{user}"
      assert Accounts.needs_welcome?(reload(user))
    end

    # ... and the profile, not the feed: a member who follows people would
    # otherwise be bounced to /feed.
    test "the redirect goes to the profile, not the feed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: user, followee: insert(:activated_user))

      conn = get(conn, ~p"/system/welcome")

      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "a logged-out visitor cannot open it", %{conn: conn} do
      conn = get(conn, ~p"/system/welcome")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "the modal over the page" do
    test "the questions float over the profile, with both closing controls real submits",
         %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      body = conn |> get(~p"/#{user}") |> html_response(200)

      assert body =~ ~s(id="welcome-modal")
      assert body =~ ~s(name="address[city]")
      assert body =~ ~s(name="user[employment_status]")
      # The form posts to the URL that handles it, not to the page it floats
      # over (the /settings form-action lesson).
      assert body =~ ~s(action="/system/welcome")

      # The ✕ and the "Skip for now" button are the same thing: a submit
      # carrying `skip`, so closing works with JS off and is what stamps the
      # questions as answered.
      closers = ~r/<button[^>]*data-welcome-skip[^>]*>/ |> Regex.scan(body) |> List.flatten()
      assert length(closers) == 2
      assert Enum.all?(closers, &(&1 =~ ~s(name="skip") and &1 =~ ~s(type="submit")))
    end

    # A toast behind the dimmed backdrop is a greeting nobody can read.
    test "no welcome toast rides along with it", %{conn: conn} do
      {conn, _user} = register_and_confirm(conn)

      refute Phoenix.Flash.get(conn.assigns.flash, :info)
    end

    test "it survives a reload and follows the member to the next page", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      assert conn |> get(~p"/#{user}") |> html_response(200) =~ ~s(id="welcome-modal")
      assert conn |> get(~p"/#{user}") |> html_response(200) =~ ~s(id="welcome-modal")
      assert conn |> get(~p"/settings/profile") |> html_response(200) =~ ~s(id="welcome-modal")
    end

    test "closing it saves nothing and never asks again", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)
      conn = get(conn, ~p"/#{user}")

      conn = submit_with_csrf(conn, ~p"/system/welcome", %{"skip" => "1"})

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user) == nil
      refute Accounts.needs_welcome?(reload(user))
      refute conn |> get(~p"/#{user}") |> html_response(200) =~ ~s(id="welcome-modal")
    end

    # The daily ad strip would sit behind the dimmed backdrop and still burn
    # the member's hourly slot on a sighting they cannot read. /community is a
    # plain controller page and carries the banner otherwise, so this goes red
    # the moment VutuvWeb.Plug.AdBanner stops asking.
    test "no ad banner rides along behind it", %{conn: conn} do
      {conn, _user} = register_and_confirm(conn)

      body = conn |> get(~p"/community") |> html_response(200)

      assert body =~ ~s(id="welcome-modal")
      refute body =~ ~s(id="vutuv-ad")
    end

    test "an ordinary login never gets it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      refute conn |> get(~p"/#{user}") |> html_response(200) =~ ~s(id="welcome-modal")
    end

    # vutuv is a German site, and a plain English render would hide an
    # untranslated island in the first thing a new member sees.
    test "renders in German for a German browser", %{conn: conn} do
      # German from the very first request: the locale plug stores what it
      # resolved in the session (and sign-up stores it on the account), so a
      # German visitor has to arrive German rather than switch afterwards.
      {conn, user} =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> register_and_confirm()

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/#{user}")
        |> html_response(200)

      assert body =~ "Art der Adresse"
      assert body =~ "Suchen Sie eine Stelle?"
      assert body =~ "Erstmal überspringen"
      # No greeting, no preamble and no "Wo sind Sie?" above the fields: the
      # window opens on the first question.
      refute body =~ "Willkommen bei vutuv"
      refute body =~ "Wo sind Sie?"
    end
  end

  describe "the form" do
    test "asks for the location and the job search", %{conn: conn} do
      {conn, _user} = register_and_confirm(conn)

      body = conn |> get(~p"/system/welcome") |> html_response(200)

      assert body =~ ~s(name="address[city]")
      assert body =~ ~s(name="address[zip_code]")
      assert body =~ ~s(name="address[country]")
      assert body =~ ~s(name="address[description]")
      assert body =~ ~s(name="user[employment_status]")
      assert body =~ ~s(name="user[employment_status_visibility]")
      assert body =~ ~s(name="user[desired_salary_min]")
      assert body =~ ~s(name="user[desired_workplace_types][]")
      # The postal code takes the cursor: it is the first field of the first
      # question, and the shortest thing to type. (Attributes render in
      # alphabetical order, so match the tag and then look inside it.)
      assert [zip_input] = Regex.run(~r/<input[^>]*name="address\[zip_code\]"[^>]*>/, body)
      assert zip_input =~ "autofocus"
      # The form posts to the URL it is served from, not to a route that only
      # exists in a test's imagination (the /settings form-action lesson).
      assert body =~ ~s(action="/system/welcome")
    end

    # vutuv is a German site, and a plain English render would hide an
    # untranslated island on the very first page a new member sees.
    test "renders in German for a German browser", %{conn: conn} do
      # German from the very first request: the locale plug stores what it
      # resolved in the session (and sign-up stores it on the account), so a
      # German visitor has to arrive German rather than switch afterwards.
      {conn, _user} =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> register_and_confirm()

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/system/welcome")
        |> html_response(200)

      assert body =~ "Art der Adresse"
      assert body =~ "Suchen Sie eine Stelle?"
      assert body =~ "Erstmal überspringen"
      # The country list is localized too — but keeps storing the English name
      # every other address in the table uses.
      assert body =~ ~s(<option value="Germany">Deutschland</option>)
      assert body =~ ~s(<option value="Austria">Österreich</option>)
    end
  end

  describe "saving the location" do
    # `Phoenix.ConnTest` skips CSRF on every conn, so the plain `post/3` tests
    # below would pass even if the rendered form could never be submitted for
    # real (the issue #759 class of bug). This one submits the token the page
    # actually rendered, through the form's own action, with CSRF enforced.
    test "the rendered form survives CSRF enforcement", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)
      conn = get(conn, ~p"/system/welcome")

      conn =
        submit_with_csrf(conn, ~p"/system/welcome", %{
          "address" => %{"description" => "Private", "city" => "Bremen"}
        })

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user).city == "Bremen"
    end

    test "a city on its own is a complete answer", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      conn =
        post(conn, ~p"/system/welcome", %{
          "address" => %{"description" => "Private", "city" => "Bremen"}
        })

      assert redirected_to(conn) == ~p"/#{user}"
      address = address_of(user)
      assert address.city == "Bremen"
      assert address.zip_code == nil
      assert address.country == nil
      assert address.description == "Private"
      refute Accounts.needs_welcome?(reload(user))
    end

    test "a postal code on its own is enough", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      post(conn, ~p"/system/welcome", %{
        "address" => %{"description" => "Work", "zip_code" => "28195"}
      })

      address = address_of(user)
      assert address.zip_code == "28195"
      assert address.city == nil
      assert address.description == "Work"
    end

    test "a country on its own is enough", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      post(conn, ~p"/system/welcome", %{"address" => %{"country" => "Germany"}})

      assert address_of(user).country == "Germany"
    end

    test "an empty location stores no address at all and is not an error", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      conn =
        post(conn, ~p"/system/welcome", %{
          "address" => %{
            "description" => "Private",
            "city" => "",
            "zip_code" => "",
            "country" => ""
          }
        })

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user) == nil
      refute Accounts.needs_welcome?(reload(user))
    end
  end

  describe "saving the job search" do
    test "stores the status, the salary floor and the workplace preference", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      post(conn, ~p"/system/welcome", %{
        "user" => %{
          "employment_status" => "looking",
          "desired_salary_min" => "60000",
          "desired_salary_period" => "year",
          "desired_salary_currency" => "EUR",
          "desired_workplace_types" => ["", "remote", "hybrid"]
        }
      })

      user = reload(user)
      assert user.employment_status == "looking"
      assert user.desired_salary_min == 60_000
      # Ticked in any order, stored in the canonical one, blanks dropped.
      assert user.desired_workplace_types == ["hybrid", "remote"]
      # The shipped visibility defaults are untouched, and they deliberately
      # differ: saying you are looking is meant to be seen, so the status opens
      # to everyone, while what you want to earn is nobody's business.
      assert user.employment_status_visibility == "everyone"
      assert user.desired_salary_visibility == "hidden"
    end

    test "the member can open their availability up to everyone right here", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      post(conn, ~p"/system/welcome", %{
        "user" => %{"employment_status" => "open", "employment_status_visibility" => "everyone"}
      })

      assert reload(user).employment_status_visibility == "everyone"
    end

    test "a workplace preference without a status is dropped", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      post(conn, ~p"/system/welcome", %{
        "user" => %{"employment_status" => "", "desired_workplace_types" => ["remote"]}
      })

      assert reload(user).desired_workplace_types == []
    end

    test "a rejected field re-renders the whole form and leaves the page open", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      conn =
        post(conn, ~p"/system/welcome", %{
          "address" => %{"description" => "Private", "city" => "Bremen"},
          "user" => %{"employment_status" => "looking", "desired_salary_min" => "0"}
        })

      body = html_response(conn, 422)
      assert body =~ ~s(name="address[city]")
      # The page IS the frame for a rejected submit, so the modal must not
      # render a second copy of the same form behind it.
      refute body =~ ~s(id="welcome-modal")
      # Nothing was written, and the member still gets their one shot at it.
      assert address_of(user) == nil
      assert Accounts.needs_welcome?(reload(user))
    end
  end

  describe "skipping" do
    test "saves nothing but closes the page for good", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)

      conn =
        post(conn, ~p"/system/welcome", %{
          "skip" => "1",
          "address" => %{"description" => "Private", "city" => "Bremen"},
          "user" => %{"employment_status" => "looking"}
        })

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user) == nil

      # No toast on the way out either: the profile's completion checklist
      # already says what is still missing.
      refute Phoenix.Flash.get(conn.assigns.flash, :info)

      user = reload(user)
      assert user.employment_status == nil
      refute Accounts.needs_welcome?(user)
    end

    test "a second submit cannot reopen the page", %{conn: conn} do
      {conn, user} = register_and_confirm(conn)
      {:ok, _} = Accounts.complete_welcome(user)

      conn = post(conn, ~p"/system/welcome", %{"address" => %{"city" => "Bremen"}})

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user) == nil
    end
  end
end
