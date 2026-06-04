defmodule Vutuv.AccountsTest do
  use Vutuv.DataCase

  alias Vutuv.Accounts
  alias Vutuv.Accounts.LoginPin
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

  # Moves a user's PIN's `created_at` `seconds_ago` into the past so the
  # private `pin_expired?/1` threshold can be exercised without sleeping.
  defp backdate_pin(user, type, seconds_ago) do
    created_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-seconds_ago, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == ^type))
    |> LoginPin.changeset(%{created_at: created_at})
    |> Repo.update!()
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
  end

  describe "get_user!/1" do
    test "returns user when exists" do
      user = insert(:user)
      found = Accounts.get_user!(user.id)
      assert found.id == user.id
    end

    test "raises when user does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(0)
      end
    end
  end

  describe "update_user/2" do
    test "updates with valid attrs" do
      user = insert(:user)
      assert {:ok, updated} = Accounts.update_user(user, %{first_name: "Updated"})
      assert updated.first_name == "Updated"
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
      # The stored value is a 64-hex-char HMAC, a per-PIN salt is present, and
      # neither equals the plaintext PIN.
      assert login_pin.pin =~ ~r/\A[0-9a-f]{64}\z/
      assert login_pin.pin != pin
      assert byte_size(login_pin.pin_salt) == 16
    end

    test "upserts a single row per (user, type)" do
      user = insert(:user)

      Accounts.gen_pin_for(user, "login")
      Accounts.gen_pin_for(user, "login")

      assert Repo.one(from(m in LoginPin, where: m.user_id == ^user.id, select: count(m.id))) == 1
    end

    test "carries a value for the email-change flow" do
      user = insert(:user)
      Accounts.gen_pin_for(user, "email", "new@example.com")

      assert Repo.one(from(m in LoginPin, where: m.user_id == ^user.id, select: m.value)) ==
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
    test "returns the count of users" do
      insert(:user)
      insert(:user)
      assert Accounts.count_users() >= 2
    end
  end
end
