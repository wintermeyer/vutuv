defmodule Vutuv.AccountsTest do
  use Vutuv.DataCase

  alias Vutuv.Accounts
  alias Vutuv.Accounts.MagicLink
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

  describe "magic_links uniqueness" do
    test "rejects a second magic link for the same user and type" do
      user = insert(:user)

      assert {:ok, _} =
               %MagicLink{user_id: user.id}
               |> MagicLink.changeset(%{magic_link: "a", magic_link_type: "login"})
               |> Repo.insert()

      assert {:error, changeset} =
               %MagicLink{user_id: user.id}
               |> MagicLink.changeset(%{magic_link: "b", magic_link_type: "login"})
               |> Repo.insert()

      assert errors_on(changeset)[:user_id] == ["already has a magic link of this type"]
    end

    test "allows different magic link types for the same user" do
      user = insert(:user)

      assert {:ok, _} =
               %MagicLink{user_id: user.id}
               |> MagicLink.changeset(%{magic_link: "a", magic_link_type: "login"})
               |> Repo.insert()

      assert {:ok, _} =
               %MagicLink{user_id: user.id}
               |> MagicLink.changeset(%{magic_link: "b", magic_link_type: "email"})
               |> Repo.insert()
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
