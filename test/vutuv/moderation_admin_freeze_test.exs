defmodule Vutuv.ModerationAdminFreezeTest do
  @moduledoc """
  The admin-initiated account freezer (issue #812): the public, audited
  `admin_freeze_user/3` / `admin_unfreeze_user/2` entry points, the frozen-list
  reads, and the withheld-status classifier that drives the honest 403/410.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
  alias Vutuv.Moderation.{AdminAction, Case}
  alias Vutuv.Repo

  defp admin, do: insert(:activated_user, admin?: true)

  defp reload(%User{id: id}), do: Repo.get!(User, id)

  defp actions_for(%User{id: id}),
    do: Repo.all(from(a in AdminAction, where: a.user_id == ^id, order_by: [asc: a.inserted_at]))

  describe "admin_freeze_user/3" do
    test "freezes an active account and records an audit row" do
      user = insert(:activated_user)
      admin = admin()

      assert {:ok, :frozen} = Moderation.admin_freeze_user(user, admin, "spam ring")

      assert reload(user).frozen_at

      assert [%AdminAction{action: "account_frozen", actor_id: actor, reason: "spam ring"}] =
               actions_for(user)

      assert actor == admin.id
    end

    test "is a no-op (no second audit row) when already frozen" do
      user = insert(:activated_user, frozen_at: NaiveDateTime.utc_now(:second))
      admin = admin()

      assert {:ok, :noop} = Moderation.admin_freeze_user(user, admin)
      assert actions_for(user) == []
    end

    test "a blank reason is stored as nil" do
      user = insert(:activated_user)

      assert {:ok, :frozen} = Moderation.admin_freeze_user(user, admin(), "   ")
      assert [%AdminAction{reason: nil}] = actions_for(user)
    end

    test "hides the profile from other members once frozen" do
      user = insert(:activated_user)
      other = insert(:activated_user)
      refute Moderation.account_hidden?(reload(user))

      {:ok, :frozen} = Moderation.admin_freeze_user(user, admin())

      frozen = reload(user)
      assert Moderation.account_hidden?(frozen)
      refute Moderation.profile_visible_to?(frozen, other)
      # Owner and admins still see it.
      assert Moderation.profile_visible_to?(frozen, frozen)
    end

    test "does not block login (frozen_at only, no suspension/deactivation)" do
      user = insert(:activated_user)
      {:ok, :frozen} = Moderation.admin_freeze_user(user, admin())

      frozen = reload(user)
      assert is_nil(Moderation.login_block(frozen))
      assert is_nil(frozen.suspended_until)
      assert is_nil(frozen.deactivated_at)
    end
  end

  describe "admin_unfreeze_user/2" do
    test "lifts a freeze and records an audit row" do
      user = insert(:activated_user, frozen_at: NaiveDateTime.utc_now(:second))
      admin = admin()

      assert {:ok, :unfrozen} = Moderation.admin_unfreeze_user(user, admin)
      refute reload(user).frozen_at
      assert [%AdminAction{action: "account_unfrozen", actor_id: actor}] = actions_for(user)
      assert actor == admin.id
    end

    test "is a no-op when the account was not frozen" do
      user = insert(:activated_user)

      assert {:ok, :noop} = Moderation.admin_unfreeze_user(user, admin())
      assert actions_for(user) == []
    end
  end

  describe "frozen-list reads" do
    test "frozen_accounts_count/0 counts only frozen_at accounts" do
      insert(:activated_user, frozen_at: NaiveDateTime.utc_now(:second))
      insert(:activated_user, deactivated_at: NaiveDateTime.utc_now(:second))
      insert(:activated_user)

      assert Moderation.frozen_accounts_count() == 1
    end

    test "list_frozen_accounts/2 returns frozen accounts newest freeze first" do
      now = NaiveDateTime.utc_now(:second)
      older = insert(:activated_user, frozen_at: NaiveDateTime.add(now, -100))
      newer = insert(:activated_user, frozen_at: now)
      _active = insert(:activated_user)

      ids = Moderation.list_frozen_accounts() |> Enum.map(& &1.id)
      assert ids == [newer.id, older.id]
    end

    test "list_frozen_accounts/2 paginates" do
      now = NaiveDateTime.utc_now(:second)

      for i <- 1..3,
          do: insert(:activated_user, frozen_at: NaiveDateTime.add(now, -i))

      page1 = Moderation.list_frozen_accounts(%{"page" => "1"}, per_page: 2)
      page2 = Moderation.list_frozen_accounts(%{"page" => "2"}, per_page: 2)

      assert length(page1) == 2
      assert length(page2) == 1
    end

    test "report_frozen_ids/1 sets apart report-frozen from admin-frozen accounts" do
      reported = insert(:activated_user, frozen_at: NaiveDateTime.utc_now(:second))
      admin_frozen = insert(:activated_user, frozen_at: NaiveDateTime.utc_now(:second))

      Repo.insert!(%Case{
        content_type: "user",
        content_id: reported.id,
        owner_id: reported.id,
        status: "escalated"
      })

      set = Moderation.report_frozen_ids([reported.id, admin_frozen.id])

      assert MapSet.member?(set, reported.id)
      refute MapSet.member?(set, admin_frozen.id)
    end
  end

  describe "withheld_status/1" do
    test "404 for a never-activated account" do
      assert Moderation.withheld_status(build(:user, email_confirmed?: false)) == 404
    end

    test "404 for a never-activated account even when frozen (anti-enumeration)" do
      user = build(:user, email_confirmed?: false, frozen_at: NaiveDateTime.utc_now(:second))
      assert Moderation.withheld_status(user) == 404
    end

    test "410 for a deactivated account" do
      user = build(:activated_user, deactivated_at: NaiveDateTime.utc_now(:second))
      assert Moderation.withheld_status(user) == 410
    end

    test "403 for a frozen, suspended, or unreachable account" do
      future = NaiveDateTime.add(NaiveDateTime.utc_now(:second), 7 * 86_400)

      assert Moderation.withheld_status(
               build(:activated_user, frozen_at: NaiveDateTime.utc_now(:second))
             ) == 403

      assert Moderation.withheld_status(build(:activated_user, suspended_until: future)) == 403

      assert Moderation.withheld_status(
               build(:activated_user, unreachable_at: NaiveDateTime.utc_now(:second))
             ) == 403
    end
  end
end
