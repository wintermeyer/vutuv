defmodule VutuvWeb.WelcomeControllerTest do
  @moduledoc """
  The one-time welcome page (/system/welcome): the location + job-search
  questions a brand-new member answers right after the registration PIN.

  The two things worth guarding are the **laxness** (any single location field
  is a complete answer, and an empty form is not an error) and the **once**
  (`welcome_completed_at` gates the redirect and the page alike, so nobody is
  nagged on later logins).
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Address

  defp address_of(user), do: Repo.one(from(a in Address, where: a.user_id == ^user.id))

  defp reload(user), do: Repo.get!(User, user.id)

  describe "arriving from the registration PIN" do
    test "the confirming PIN lands on the welcome page", %{conn: conn} do
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

      assert redirected_to(conn) == ~p"/system/welcome"
    end

    test "an ordinary login goes home, never to the welcome page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "a member who already left the page behind is sent home by it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Accounts.complete_welcome(user)

      conn = get(conn, ~p"/system/welcome")

      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "a logged-out visitor cannot open it", %{conn: conn} do
      conn = get(conn, ~p"/system/welcome")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "the form" do
    test "asks for the location and the job search", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/system/welcome") |> html_response(200)

      assert body =~ ~s(name="address[city]")
      assert body =~ ~s(name="address[zip_code]")
      assert body =~ ~s(name="address[country]")
      assert body =~ ~s(name="address[description]")
      assert body =~ ~s(name="user[employment_status]")
      assert body =~ ~s(name="user[employment_status_visibility]")
      assert body =~ ~s(name="user[desired_salary_min]")
      assert body =~ ~s(name="user[desired_workplace_type]")
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
      {conn, _user} = create_and_login_user(conn)

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/system/welcome")
        |> html_response(200)

      assert body =~ "Wo sind Sie?"
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
      {conn, user} = create_and_login_user(conn)
      conn = get(conn, ~p"/system/welcome")

      conn =
        submit_with_csrf(conn, ~p"/system/welcome", %{
          "address" => %{"description" => "Private", "city" => "Bremen"}
        })

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user).city == "Bremen"
    end

    test "a city on its own is a complete answer", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

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
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/system/welcome", %{
        "address" => %{"description" => "Work", "zip_code" => "28195"}
      })

      address = address_of(user)
      assert address.zip_code == "28195"
      assert address.city == nil
      assert address.description == "Work"
    end

    test "a country on its own is enough", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/system/welcome", %{"address" => %{"country" => "Germany"}})

      assert address_of(user).country == "Germany"
    end

    test "an empty location stores no address at all and is not an error", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

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
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/system/welcome", %{
        "user" => %{
          "employment_status" => "looking",
          "desired_salary_min" => "60000",
          "desired_salary_period" => "year",
          "desired_salary_currency" => "EUR",
          "desired_workplace_type" => "remote"
        }
      })

      user = reload(user)
      assert user.employment_status == "looking"
      assert user.desired_salary_min == 60_000
      assert user.desired_workplace_type == "remote"
      # The shipped visibility defaults are untouched: the status shows to
      # signed-in members, the salary to nobody.
      assert user.employment_status_visibility == "members"
      assert user.desired_salary_visibility == "hidden"
    end

    test "the member can open their availability up to everyone right here", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/system/welcome", %{
        "user" => %{"employment_status" => "open", "employment_status_visibility" => "everyone"}
      })

      assert reload(user).employment_status_visibility == "everyone"
    end

    test "a workplace preference without a status is dropped", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/system/welcome", %{
        "user" => %{"employment_status" => "", "desired_workplace_type" => "remote"}
      })

      assert reload(user).desired_workplace_type == nil
    end

    test "a rejected field re-renders the whole form and leaves the page open", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/system/welcome", %{
          "address" => %{"description" => "Private", "city" => "Bremen"},
          "user" => %{"employment_status" => "looking", "desired_salary_min" => "0"}
        })

      assert html_response(conn, 422) =~ ~s(name="address[city]")
      # Nothing was written, and the member still gets their one shot at it.
      assert address_of(user) == nil
      assert Accounts.needs_welcome?(reload(user))
    end
  end

  describe "skipping" do
    test "saves nothing but closes the page for good", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/system/welcome", %{
          "skip" => "1",
          "address" => %{"description" => "Private", "city" => "Bremen"},
          "user" => %{"employment_status" => "looking"}
        })

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user) == nil

      # The newcomer greeting the login held back while this page was in the
      # way arrives here, on the way to the profile it talks about.
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome to vutuv"

      user = reload(user)
      assert user.employment_status == nil
      refute Accounts.needs_welcome?(user)
    end

    test "a second submit cannot reopen the page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Accounts.complete_welcome(user)

      conn = post(conn, ~p"/system/welcome", %{"address" => %{"city" => "Bremen"}})

      assert redirected_to(conn) == ~p"/#{user}"
      assert address_of(user) == nil
    end
  end
end
