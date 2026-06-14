defmodule Vutuv.AccountsTest do
  use Vutuv.DataCase

  alias Vutuv.Accounts
  alias Vutuv.Accounts.LoginPin
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  @valid_registration %{
    "emails" => %{"0" => %{"value" => "test@example.com"}},
    "first_name" => "Test",
    "last_name" => "User"
  }

  defp build_conn do
    %Plug.Conn{
      assigns: %{locale: "en"},
      private: %{plug_session: %{}, plug_session_fetch: :done}
    }
    |> Plug.Test.init_test_session(%{})
  end

  # Moves a user's PIN's `minted_at` `seconds_ago` into the past so the
  # private `pin_expired?/1` threshold can be exercised without sleeping.
  defp backdate_pin(user, type, seconds_ago) do
    minted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-seconds_ago, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == ^type))
    |> LoginPin.changeset(%{minted_at: minted_at})
    |> Repo.update!()
  end

  # Builds an account exactly as a sign-up does — user + a "login" PIN minted
  # alongside it — then ages both `minutes` into the past so the sweep threshold
  # can be exercised without sleeping.
  defp pending_registration(opts) do
    minutes = Keyword.get(opts, :age_minutes, 0)
    email_confirmed? = Keyword.get(opts, :email_confirmed?, false)

    user = insert(:user, email_confirmed?: email_confirmed?)
    Accounts.gen_pin_for(user, "login")
    set_inserted_at(from(u in User, where: u.id == ^user.id), minutes)
    set_inserted_at(from(p in LoginPin, where: p.user_id == ^user.id), minutes)
    user
  end

  defp set_inserted_at(query, minutes_ago) do
    ts =
      NaiveDateTime.utc_now(:second)
      |> NaiveDateTime.add(-minutes_ago * 60)

    Repo.update_all(query, set: [inserted_at: ts])
  end

  describe "register_user/2" do
    test "creates a user with valid attrs" do
      conn = build_conn()
      assert {:ok, %User{} = user} = Accounts.register_user(conn, @valid_registration)
      assert user.first_name == "Test"
      assert user.last_name == "User"
      assert user.active_slug != nil
    end

    test "fails with missing name" do
      conn = build_conn()
      attrs = %{"emails" => %{"0" => %{"value" => "test@example.com"}}}
      assert {:error, _changeset} = Accounts.register_user(conn, attrs)
    end

    test "ignores an email_confirmed? flag smuggled into the params" do
      conn = build_conn()
      attrs = Map.put(@valid_registration, "email_confirmed?", "true")

      assert {:ok, %User{} = user} = Accounts.register_user(conn, attrs)
      refute user.email_confirmed?
    end
  end

  describe "update_user/2" do
    test "updates with valid attrs" do
      user = insert(:user)
      assert {:ok, updated} = Accounts.update_user(user, %{first_name: "Updated"})
      assert updated.first_name == "Updated"
    end

    test "ignores an email_confirmed? flag smuggled into the params" do
      user = insert(:user, email_confirmed?: false)

      assert {:ok, updated} =
               Accounts.update_user(user, %{
                 "first_name" => "Updated",
                 "email_confirmed?" => "true"
               })

      refute updated.email_confirmed?
    end

    test "rebuilds the people-search index when the name changes (API rename stays in sync)" do
      user = insert(:user, first_name: "Jane", last_name: "Doe")

      for cs <-
            SearchTerm.create_search_terms(%{
              "first_name" => "Jane",
              "last_name" => "Doe"
            }) do
        cs |> Ecto.Changeset.put_change(:user_id, user.id) |> Repo.insert!()
      end

      {:ok, _} = Accounts.update_user(user, %{"last_name" => "Smith"})

      terms =
        Repo.all(from(s in SearchTerm, where: s.user_id == ^user.id, select: s.value))
        |> Enum.map(&String.downcase/1)

      assert Enum.any?(terms, &String.contains?(&1, "smith"))
      refute Enum.any?(terms, &String.contains?(&1, "doe"))
    end

    test "a name change does not wipe the index when one name key is omitted" do
      user = insert(:user, first_name: "Jane", last_name: "Doe")

      {:ok, _} = Accounts.update_user(user, %{"first_name" => "Janet"})

      terms = Repo.all(from(s in SearchTerm, where: s.user_id == ^user.id))
      refute terms == []
    end
  end

  describe "login_pins uniqueness" do
    test "rejects a second login pin for the same user and type" do
      user = insert(:user)

      assert {:ok, _} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "login"})
               |> Repo.insert()

      assert {:error, changeset} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "login"})
               |> Repo.insert()

      assert errors_on(changeset)[:user_id] == ["already has a login pin of this type"]
    end

    test "allows different login pin types for the same user" do
      user = insert(:user)

      assert {:ok, _} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "login"})
               |> Repo.insert()

      assert {:ok, _} =
               %LoginPin{user_id: user.id}
               |> LoginPin.changeset(%{type: "email"})
               |> Repo.insert()
    end
  end

  describe "gen_pin_for/3" do
    test "returns a fresh 6-digit PIN and never stores it in plaintext" do
      user = insert(:user)

      pin = Accounts.gen_pin_for(user, "login")

      assert pin =~ ~r/\A\d{6}\z/

      login_pin = Repo.one(from(m in LoginPin, where: m.user_id == ^user.id))
      # The stored hash is a 64-hex-char HMAC, a per-PIN salt is present, and
      # neither equals the plaintext PIN.
      assert login_pin.pin_hash =~ ~r/\A[0-9a-f]{64}\z/
      assert login_pin.pin_hash != pin
      assert byte_size(login_pin.pin_salt) == 16
    end

    test "upserts a single row per (user, type)" do
      user = insert(:user)

      Accounts.gen_pin_for(user, "login")
      Accounts.gen_pin_for(user, "login")

      assert Repo.one(from(m in LoginPin, where: m.user_id == ^user.id, select: count(m.id))) == 1
    end

    test "concurrent first mints for a (user, type) pair never raise" do
      user = insert(:user)

      pins =
        Task.await_many(
          for _ <- 1..4 do
            Task.async(fn -> Accounts.gen_pin_for(user, "email", "new@example.com") end)
          end
        )

      assert Enum.all?(pins, &(byte_size(&1) == 6))

      assert Repo.aggregate(
               from(m in LoginPin, where: m.user_id == ^user.id and m.type == "email"),
               :count
             ) == 1
    end

    test "carries a payload for the email-change flow" do
      user = insert(:user)
      Accounts.gen_pin_for(user, "email", "new@example.com")

      assert Repo.one(from(m in LoginPin, where: m.user_id == ^user.id, select: m.payload)) ==
               "new@example.com"
    end
  end

  describe "check_pin/3" do
    test "accepts the correct PIN once and consumes it" do
      user = insert(:user)
      pin = Accounts.gen_pin_for(user, "delete")

      assert {:ok, %User{id: id}} = Accounts.check_pin(user, pin, "delete")
      assert id == user.id

      # A consumed PIN is expired and cannot be replayed.
      assert {:expired, _} = Accounts.check_pin(user, pin, "delete")
    end

    test "returns the carried value for the email-change flow" do
      user = insert(:user)
      pin = Accounts.gen_pin_for(user, "email", "new@example.com")

      assert {:ok, "new@example.com", %User{id: id}} = Accounts.check_pin(user, pin, "email")
      assert id == user.id
    end

    test "rejects a wrong PIN and locks out after three attempts" do
      user = insert(:user)
      _pin = Accounts.gen_pin_for(user, "delete")

      assert {:error, _} = Accounts.check_pin(user, "000000", "delete")
      assert {:error, _} = Accounts.check_pin(user, "000000", "delete")
      assert :lockout = Accounts.check_pin(user, "000000", "delete")
    end

    test "verifies a login PIN by email" do
      user = insert(:user)
      insert(:email, user: user, value: "login@example.com")
      pin = Accounts.gen_pin_for(user, "login")

      assert {:ok, %User{id: id}} = Accounts.check_pin("login@example.com", pin, "login")
      assert id == user.id
    end

    test "errors when no PIN exists for the identity" do
      user = insert(:user)
      assert {:error, _} = Accounts.check_pin(user, "123456", "delete")
    end

    # Guards the float/second day-arithmetic rewrite of `pin_expired?/1`: a PIN is
    # accepted just inside the 1800s window and rejected as expired just past it.
    test "honours the PIN expiry window (still valid before, expired after)" do
      user = insert(:user)
      pin = Accounts.gen_pin_for(user, "delete")

      backdate_pin(user, "delete", 1799)
      assert {:ok, %User{}} = Accounts.check_pin(user, pin, "delete")

      pin = Accounts.gen_pin_for(user, "delete")
      backdate_pin(user, "delete", 1801)
      assert {:expired, _} = Accounts.check_pin(user, pin, "delete")
    end
  end

  describe "count_users/0" do
    test "counts confirmed members (activated, or legacy nil-activated)" do
      base = Accounts.count_users()
      insert(:activated_user)
      insert(:activated_user)
      insert(:user, email_confirmed?: nil)
      assert Accounts.count_users() == base + 3
    end

    test "excludes never-confirmed registrations (email_confirmed? == false, issue #781)" do
      base = Accounts.count_users()
      insert(:user)
      insert(:user)
      assert Accounts.count_users() == base
    end
  end

  describe "delete_unconfirmed_registrations/1" do
    test "deletes a registration that never confirmed its PIN once it is over an hour old" do
      user = pending_registration(age_minutes: 61)

      assert Accounts.delete_unconfirmed_registrations() == 1
      refute Repo.get(User, user.id)
    end

    test "spares a registration younger than the threshold" do
      user = pending_registration(age_minutes: 30)

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end

    test "spares an account that has been activated, however old" do
      user = pending_registration(age_minutes: 1_000, email_confirmed?: true)

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end

    # The critical safety case: an established (e.g. legacy) member is
    # `email_confirmed?: false` and mints a fresh "login" PIN when they try to sign in.
    # Because that PIN was created long after the account, it must NOT be reaped
    # as an abandoned registration.
    test "never deletes a legacy member who merely failed to log in" do
      user = insert(:user, email_confirmed?: false)
      set_inserted_at(from(u in User, where: u.id == ^user.id), 60 * 24 * 365 * 5)
      # They attempt a login now: a brand-new PIN, years after the account.
      Accounts.gen_pin_for(user, "login")

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end

    test "never deletes an unconfirmed account that has no login PIN at all" do
      user = insert(:user, email_confirmed?: false)
      set_inserted_at(from(u in User, where: u.id == ^user.id), 1_000)

      assert Accounts.delete_unconfirmed_registrations() == 0
      assert Repo.get(User, user.id)
    end
  end
end
