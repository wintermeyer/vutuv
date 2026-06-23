defmodule VutuvWeb.HomeTest do
  use VutuvWeb.ConnCase, async: true

  alias VutuvWeb.Home

  # Home is the feed once a member follows at least one (activated, non-hidden)
  # account, otherwise their own profile — so a brand-new member never lands on
  # an empty feed. Login, the logged-out-only guard and the shell logo all
  # resolve through Home.path/1, so this is where the rule is pinned down.
  describe "path/1" do
    test "is the member's own profile until they follow someone" do
      user = insert(:user)

      assert Home.path(user) == ~p"/#{user}"
    end

    test "becomes the feed once the member follows at least one (activated) account" do
      user = insert(:user)
      insert(:follow, follower: user, followee: insert(:activated_user))

      assert Home.path(user) == ~p"/feed"
    end

    test "ignores follows of unconfirmed accounts (whose posts the feed hides anyway)" do
      user = insert(:user)
      insert(:follow, follower: user, followee: insert(:user, email_confirmed?: false))

      assert Home.path(user) == ~p"/#{user}"
    end
  end
end
