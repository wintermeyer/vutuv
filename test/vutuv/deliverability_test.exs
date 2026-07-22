defmodule Vutuv.DeliverabilityTest do
  @moduledoc """
  A confirmed account with no deliverable email left is frozen as unreachable -
  but only after repeated hard bounces or a long-dead address, never on one
  bounce or while another address still works. A working address (admin action,
  or a login PIN) thaws it. Every transition is written to the audit ledger.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.Deliverability
  alias Vutuv.Deliverability.Event
  alias Vutuv.Moderation
  alias Vutuv.Notifications.EmailBounce
  alias Vutuv.Repo

  defp confirmed_user_with_emails(addresses) do
    user = insert(:activated_user)
    for value <- addresses, do: insert(:email, user: user, value: value)
    user
  end

  defp reload(%User{id: id}), do: Repo.get!(User, id)
  defp reload_email(value), do: Repo.get_by!(Email, value: value)

  defp mark_dead(value, ago_days \\ 0) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -ago_days * 86_400, :second)

    {1, _} =
      Repo.update_all(from(e in Email, where: e.value == ^value), set: [undeliverable_at: at])

    :ok
  end

  defp actions_for(%User{id: id}) do
    Deliverability.events_for_user(id) |> Enum.map(& &1.action)
  end

  # Real reply-text shapes from the production mail.log (all arrive as the
  # generic dsn=5.0.0, so only the text tells them apart).
  @quota_raw "host mx.gmx.net said: 552-Requested mail action aborted: exceeded storage allocation 552-Quota exceeded"
  @blocked_raw "host bar.example said: 550 permanent failure for one or more recipients (x@y:blocked)"
  @dead_raw "host mx.ionos.de said: 550-Requested action not taken: mailbox unavailable"

  # Reproduces the misclassification's end state: the address was marked
  # undeliverable (as the old classifier did), and the grace-period sweep froze
  # the owner.
  defp frozen_user_with_bounce(address, raw) do
    user = confirmed_user_with_emails([address])
    mark_dead(address, Deliverability.grace_days() + 1)
    insert(:email_bounce, email_value: address, status: "5.0.0", raw: raw)
    Deliverability.reassess_user(user)
    user
  end

  describe "record_hard_bounce/3" do
    test "marks the address undeliverable, ledgers the bounce, logs deactivation" do
      user = confirmed_user_with_emails(["dead@example.com"])

      Deliverability.record_hard_bounce("dead@example.com", "5.1.1", "550 5.1.1 User unknown")

      assert reload_email("dead@example.com").undeliverable_at
      assert [%EmailBounce{status: "5.1.1", action: "failed"}] = Repo.all(EmailBounce)
      assert "address_deactivated" in actions_for(user)
    end

    test "an address we do not know is still ledgered, no freeze" do
      Deliverability.record_hard_bounce("nobody@example.com", "5.1.1", "raw")
      assert [%EmailBounce{email_value: "nobody@example.com"}] = Repo.all(EmailBounce)
      assert Repo.all(Event) == []
    end

    test "an oversized bounced address is sliced to fit the varchar(255) column, never a 22001" do
      long = String.duplicate("a", 300) <> "@example.com"

      assert :ok = Deliverability.record_hard_bounce(long, "5.1.1", "raw")

      assert [%EmailBounce{email_value: stored}] = Repo.all(EmailBounce)
      assert String.length(stored) <= 255
    end

    test "a second hard bounce on the sole address freezes the account" do
      user = confirmed_user_with_emails(["dead@example.com"])

      Deliverability.record_hard_bounce("dead@example.com", "5.1.1", "raw")
      refute reload(user).unreachable_at

      Deliverability.record_hard_bounce("dead@example.com", "5.1.2", "raw")
      assert reload(user).unreachable_at
      assert "account_frozen" in actions_for(user)
    end
  end

  describe "reassess_user/1 freeze gate" do
    test "does not freeze while another address still works" do
      user = confirmed_user_with_emails(["dead@example.com", "fine@example.com"])
      mark_dead("dead@example.com")
      insert(:email_bounce, email_value: "dead@example.com", status: "5.1.1")
      insert(:email_bounce, email_value: "dead@example.com", status: "5.1.1")

      Deliverability.reassess_user(user)
      refute reload(user).unreachable_at
    end

    test "does not freeze an unconfirmed account" do
      user = insert(:user)
      insert(:email, user: user, value: "dead@example.com")
      mark_dead("dead@example.com")
      insert(:email_bounce, email_value: "dead@example.com", status: "5.1.1")
      insert(:email_bounce, email_value: "dead@example.com", status: "5.1.1")

      Deliverability.reassess_user(user)
      refute reload(user).unreachable_at
    end

    test "freezes via the grace period without a second bounce" do
      user = confirmed_user_with_emails(["dead@example.com"])
      mark_dead("dead@example.com", Deliverability.grace_days() + 1)

      Deliverability.reassess_user(user)

      assert reload(user).unreachable_at

      assert [%Event{action: "account_frozen", detail: %{"reason" => "grace_period"}}] =
               Repo.all(from(ev in Event, where: ev.action == "account_frozen"))
    end

    test "policy bounces (5.7.x) never count toward a freeze" do
      user = confirmed_user_with_emails(["dead@example.com"])
      mark_dead("dead@example.com")
      for _ <- 1..3, do: insert(:email_bounce, email_value: "dead@example.com", status: "5.7.26")

      Deliverability.reassess_user(user)
      refute reload(user).unreachable_at
    end

    test "generic 5.0.0 ledger rows count only when their text confirms a dead recipient" do
      quota_raw = "host mx.gmx.net said: 552-Quota exceeded 552 storage allocation"
      user = confirmed_user_with_emails(["full@example.com"])
      mark_dead("full@example.com")

      for _ <- 1..2,
          do:
            insert(:email_bounce,
              email_value: "full@example.com",
              status: "5.0.0",
              raw: quota_raw
            )

      Deliverability.reassess_user(user)
      refute reload(user).unreachable_at

      dead_raw = "host mx00.ionos.de said: 550-Requested action not taken: mailbox unavailable"
      other = confirmed_user_with_emails(["gone@example.com"])
      mark_dead("gone@example.com")

      for _ <- 1..2,
          do:
            insert(:email_bounce, email_value: "gone@example.com", status: "5.0.0", raw: dead_raw)

      Deliverability.reassess_user(other)
      assert reload(other).unreachable_at
    end
  end

  describe "thawing" do
    test "reassess thaws once an address works again" do
      user = confirmed_user_with_emails(["dead@example.com"])
      mark_dead("dead@example.com", Deliverability.grace_days() + 1)
      Deliverability.reassess_user(user)
      assert reload(user).unreachable_at

      # A new working address appears; the freeze must lift.
      insert(:email, user: user, value: "fresh@example.com")
      Deliverability.reassess_user(user)

      refute reload(user).unreachable_at
      assert "account_thawed" in actions_for(user)
    end

    test "an admin can thaw a frozen account" do
      admin = insert(:activated_user, admin?: true)
      user = confirmed_user_with_emails(["dead@example.com"])
      mark_dead("dead@example.com", Deliverability.grace_days() + 1)
      Deliverability.reassess_user(user)

      assert {:ok, :thawed} = Deliverability.thaw(reload(user), admin)
      refute reload(user).unreachable_at

      assert [%Event{actor_id: actor_id, detail: %{"reason" => "admin"}}] =
               Repo.all(from(ev in Event, where: ev.action == "account_thawed"))

      assert actor_id == admin.id
    end

    test "thawing an account that is not frozen is a no-op" do
      admin = insert(:activated_user, admin?: true)
      user = confirmed_user_with_emails(["fine@example.com"])
      assert {:ok, :noop} = Deliverability.thaw(user, admin)
    end

    test "an admin clearing the dead address thaws the account" do
      admin = insert(:activated_user, admin?: true)
      user = confirmed_user_with_emails(["dead@example.com"])
      mark_dead("dead@example.com", Deliverability.grace_days() + 1)
      Deliverability.reassess_user(user)

      email = reload_email("dead@example.com")
      assert {:ok, :cleared} = Deliverability.clear_address(email, admin)

      refute reload_email("dead@example.com").undeliverable_at
      refute reload(user).unreachable_at
    end
  end

  describe "sweep_unreachable/0" do
    test "freezes a confirmed account whose sole address is long dead" do
      stale = confirmed_user_with_emails(["stale@example.com"])
      mark_dead("stale@example.com", Deliverability.grace_days() + 1)

      # A recently-dead account is not yet swept.
      recent = confirmed_user_with_emails(["recent@example.com"])
      mark_dead("recent@example.com", 1)

      assert Deliverability.sweep_unreachable() >= 1

      assert reload(stale).unreachable_at
      refute reload(recent).unreachable_at
    end
  end

  describe "repair_misclassified_bounces/0" do
    test "clears quota/blocked-only addresses and thaws their owners" do
      quota_user = frozen_user_with_bounce("full@example.com", @quota_raw)
      blocked_user = frozen_user_with_bounce("filterblocked@example.com", @blocked_raw)
      assert reload(quota_user).unreachable_at
      assert reload(blocked_user).unreachable_at

      assert %{cleared: 2, thawed: 2} = Deliverability.repair_misclassified_bounces()

      refute reload_email("full@example.com").undeliverable_at
      refute reload(quota_user).unreachable_at
      refute reload_email("filterblocked@example.com").undeliverable_at
      refute reload(blocked_user).unreachable_at

      # The audit trail names the repair on the recovery, and the thaw follows.
      assert [%Event{detail: %{"reason" => "misclassified_bounce"}} | _] =
               Deliverability.events_for_user(quota_user.id)
               |> Enum.filter(&(&1.action == "address_recovered"))

      assert "account_thawed" in actions_for(quota_user)
    end

    test "a genuinely dead address and its frozen owner are untouched" do
      dead_user = frozen_user_with_bounce("gone@example.com", @dead_raw)

      assert %{cleared: 0, thawed: 0} = Deliverability.repair_misclassified_bounces()

      assert reload_email("gone@example.com").undeliverable_at
      assert reload(dead_user).unreachable_at
    end

    test "an address with any confirmed hard bounce is untouched, even beside a quota row" do
      user = confirmed_user_with_emails(["mixed@example.com"])
      mark_dead("mixed@example.com", Deliverability.grace_days() + 1)
      insert(:email_bounce, email_value: "mixed@example.com", status: "5.0.0", raw: @quota_raw)

      insert(:email_bounce,
        email_value: "mixed@example.com",
        status: "5.1.1",
        raw: "550 5.1.1 User unknown"
      )

      Deliverability.reassess_user(user)

      assert %{cleared: 0, thawed: 0} = Deliverability.repair_misclassified_bounces()
      assert reload(user).unreachable_at
    end

    test "an undeliverable address without ledger evidence is untouched" do
      confirmed_user_with_emails(["noledger@example.com"])
      mark_dead("noledger@example.com")

      assert %{cleared: 0, thawed: 0} = Deliverability.repair_misclassified_bounces()
      assert reload_email("noledger@example.com").undeliverable_at
    end

    test "running the repair twice is a no-op the second time" do
      frozen_user_with_bounce("full2@example.com", @quota_raw)

      assert %{cleared: 1, thawed: 1} = Deliverability.repair_misclassified_bounces()
      assert %{cleared: 0, thawed: 0} = Deliverability.repair_misclassified_bounces()
    end
  end

  describe "visibility integration" do
    test "an unreachable account is hidden from strangers, visible to owner and admins" do
      admin = insert(:activated_user, admin?: true)
      stranger = insert(:activated_user)
      user = confirmed_user_with_emails(["dead@example.com"])
      mark_dead("dead@example.com", Deliverability.grace_days() + 1)
      Deliverability.reassess_user(user)
      user = reload(user)

      assert Moderation.account_hidden?(user)
      refute Moderation.profile_visible_to?(user, stranger)
      assert Moderation.profile_visible_to?(user, user)
      assert Moderation.profile_visible_to?(user, admin)
    end
  end
end
