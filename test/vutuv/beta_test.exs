defmodule Vutuv.BetaTest do
  @moduledoc """
  Beta features are opt-in for everybody, admins included: nobody gets one
  because of who they are, only because they switched it on. An admin-audience
  feature is merely *offered* to admins and nobody else.

  Sync because `Vutuv.BetaHelpers.with_beta_features/1` swaps the registry
  through a global application env.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.BetaHelpers

  alias Vutuv.Beta

  setup do
    with_beta_features()

    member = insert(:user)
    admin = insert(:user, admin?: true)
    %{member: member, admin: admin}
  end

  describe "available/1" do
    test "a member is offered the member features only", %{member: member} do
      assert Enum.map(Beta.available(member), & &1.key) == [:test_member_feature]
    end

    test "an admin is offered both", %{admin: admin} do
      assert Enum.map(Beta.available(admin), & &1.key) ==
               [:test_member_feature, :test_admin_feature]
    end

    test "a visitor who is not signed in is offered nothing" do
      assert Beta.available(nil) == []
    end
  end

  describe "enabled?/2" do
    test "is off until the member switches it on", %{member: member} do
      refute Beta.enabled?(member, :test_member_feature)

      {:ok, member} = Beta.choose(member, ["test_member_feature"])

      assert Beta.enabled?(member, :test_member_feature)
    end

    test "an admin does not get an admin feature without opting in", %{admin: admin} do
      refute Beta.enabled?(admin, :test_admin_feature)

      {:ok, admin} = Beta.choose(admin, ["test_admin_feature"])

      assert Beta.enabled?(admin, :test_admin_feature)
    end

    test "a member cannot switch on an admin feature", %{member: member} do
      {:ok, member} = Beta.choose(member, ["test_admin_feature", "test_member_feature"])

      assert member.beta_features == ["test_member_feature"]
      refute Beta.enabled?(member, :test_admin_feature)
    end

    test "an admin feature switches off when the admin loses the role", %{admin: admin} do
      {:ok, admin} = Beta.choose(admin, ["test_admin_feature"])

      refute Beta.enabled?(%{admin | admin?: false}, :test_admin_feature)
    end

    test "is false for a visitor who is not signed in" do
      refute Beta.enabled?(nil, :test_member_feature)
    end

    # A typo or a call site left behind after the feature graduated must fail
    # in the test suite, not quietly answer false in production.
    test "raises for a key the registry does not know", %{member: member} do
      assert_raise ArgumentError, fn -> Beta.enabled?(member, :no_such_feature) end
    end
  end

  describe "choose/2" do
    test "drops keys of features that no longer exist", %{member: member} do
      {:ok, member} =
        member
        |> Ecto.Changeset.change(beta_features: ["graduated_feature"])
        |> Repo.update()

      {:ok, member} = Beta.choose(member, ["test_member_feature"])

      assert member.beta_features == ["test_member_feature"]
    end

    test "an empty choice switches everything off", %{member: member} do
      {:ok, member} = Beta.choose(member, ["test_member_feature"])
      {:ok, member} = Beta.choose(member, [])

      assert member.beta_features == []
    end
  end
end
