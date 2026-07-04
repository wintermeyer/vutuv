defmodule Vutuv.Accounts.AdminPromotionTest do
  # The first admin of an installation is minted from the command line
  # (`mix vutuv.admin.promote`, or `Vutuv.Release.promote_admin/1` on a
  # release) — admin? is deliberately never castable through any form or API.
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts

  test "promotes a member by @handle" do
    user = insert(:activated_user)

    assert {:ok, promoted} = Accounts.promote_admin(user.username)
    assert promoted.admin?
    assert Accounts.get_user(user.id).admin?
  end

  test "promotes a member by email address" do
    user = insert(:activated_user)
    email = insert(:email, user: user)

    assert {:ok, promoted} = Accounts.promote_admin(email.value)
    assert promoted.id == user.id
    assert Accounts.get_user(user.id).admin?
  end

  test "is idempotent for an existing admin" do
    user = insert(:activated_user)
    {:ok, _} = Accounts.promote_admin(user.username)

    assert {:ok, promoted} = Accounts.promote_admin(user.username)
    assert promoted.admin?
  end

  test "returns not_found for an unknown identifier" do
    assert {:error, :not_found} = Accounts.promote_admin("nobody-here")
    assert {:error, :not_found} = Accounts.promote_admin("nobody@example.com")
  end
end
