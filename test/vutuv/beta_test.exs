defmodule Vutuv.BetaTest do
  @moduledoc """
  One switch per member decides every beta feature, and it works the same for
  every kind of account: an admin gets nothing a member would not.

  Sync because `Vutuv.BetaHelpers.with_beta_features/1` swaps the registry
  through a global application env.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.BetaHelpers

  alias Vutuv.Beta

  setup do
    with_beta_features()
  end

  describe "enabled?/2" do
    test "is on for a member who switched on beta" do
      assert Beta.enabled?(insert(:user, beta?: true), :test_feature)
    end

    test "is off for a member who did not" do
      refute Beta.enabled?(insert(:user), :test_feature)
    end

    test "an admin gets nothing without switching beta on" do
      refute Beta.enabled?(insert(:user, admin?: true), :test_feature)
      assert Beta.enabled?(insert(:user, admin?: true, beta?: true), :test_feature)
    end

    test "is off for a visitor who is not signed in" do
      refute Beta.enabled?(nil, :test_feature)
    end

    # A typo or a call site left behind after the feature graduated must fail
    # in the test suite, not quietly answer false in production.
    test "raises for a key the registry does not know" do
      assert_raise ArgumentError, fn ->
        Beta.enabled?(insert(:user, beta?: true), :no_such_feature)
      end
    end
  end
end
