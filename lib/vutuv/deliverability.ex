defmodule Vutuv.Deliverability do
  @moduledoc """
  Turns a confirmed hard bounce into action: deactivate the dead address, and
  freeze the account if it has become permanently unreachable.

  Both bounce signal sources funnel through `record_hard_bounce/3`: the
  production log watcher (`Vutuv.Deliverability.Watcher`, the path actually used
  in prod) and the DSN webhook (`Vutuv.Notifications.Bounces.record/1`). Each
  hard bounce:

    1. appends to the bounce ledger (`EmailBounce`),
    2. marks the address undeliverable (`emails.undeliverable_at`), so
       `Emailer.deliver/1` drops automatic mail to it (PIN mail still goes), and
    3. re-assesses the owner's reachability (`reassess_user/1`).

  ## When an account is frozen (and un-frozen)

  Login is by any of a member's addresses, so an account is only *unreachable*
  when **every** address has bounced. `reassess_user/1` freezes
  (`users.unreachable_at`) a **confirmed** account with no deliverable address
  left, but only after repeated failures (`@min_hard_bounces` hard bounces) or
  once an address has been dead past a grace period (`@grace_days`) - never on a
  single bounce, because bounces can be transient or policy-side
  (see `Vutuv.Deliverability.MailLog`).

  A frozen account is hidden from other members like a moderation freeze
  (`Vutuv.Moderation.account_hidden?` reads `unreachable_at`), but stays visible
  to the owner and admins. It un-freezes automatically when a login PIN proves
  an address works again (`Vutuv.Accounts.check_pin/3` re-assesses), or when an
  admin thaws it from the deliverability dashboard.

  Every transition is written to the `deliverability_events` ledger, so the
  admin dashboard can show the full history and who acted.
  """

  import Ecto.Query

  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.Deliverability.{Event, MailLog}
  alias Vutuv.Notifications.{Bounces, EmailBounce}
  alias Vutuv.Repo

  # Repeated-failure gate: this many hard bounces (across the owner's dead
  # addresses) before a freeze. The first bounce stops automatic mail, so a
  # second one means the way back in (PIN mail) is failing too, or automatic
  # mail bounced again after a recovery - a real "still broken" signal.
  @min_hard_bounces 2
  # Time gate: an address dead this long (with no other reachable address)
  # freezes the account even without a second bounce, via the daily sweeper.
  @grace_days 7

  @doc "The repeated-failure threshold (exposed for the sweeper/tests)."
  def min_hard_bounces, do: @min_hard_bounces

  @doc "The grace period in days before a long-dead address freezes its account."
  def grace_days, do: @grace_days

  @doc """
  Records one confirmed hard bounce for `address` (`dsn` is the enhanced status
  code, `raw` the source DSN or log line). Appends to the ledger, marks the
  address undeliverable, and re-assesses the owner. Idempotent enough for the
  watcher: re-marking an already-dead address keeps its original timestamp.
  """
  def record_hard_bounce(address, dsn, raw) when is_binary(address) do
    address = String.downcase(address)
    now = NaiveDateTime.utc_now(:second)

    Repo.insert!(%EmailBounce{
      email_value: address,
      action: "failed",
      status: dsn,
      raw: String.slice(raw || "", 0, 100_000)
    })

    {transitioned, _} =
      from(e in Email, where: e.value == ^address and is_nil(e.undeliverable_at))
      |> Repo.update_all(set: [undeliverable_at: now])

    case user_for_address(address) do
      %User{} = user ->
        if transitioned > 0,
          do:
            log("address_deactivated", user_id: user.id, email: address, detail: %{"dsn" => dsn})

        reassess_user(user)

      nil ->
        :ok
    end
  end

  @doc """
  Re-evaluates a member's reachability and freezes or thaws as needed. Safe to
  call repeatedly; only acts on a genuine state change.
  """
  def reassess_user(%User{id: id}), do: reassess_user(id)

  def reassess_user(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> do_reassess(user)
      nil -> :ok
    end
  end

  @doc """
  Daily sweep (`Vutuv.Deliverability.Sweeper`): re-assesses confirmed accounts
  with an address dead past the grace period. This is the time-based freeze
  trigger - once the first bounce stops automatic mail, no second bounce may
  ever arrive, so a long-dead sole address would otherwise never freeze.
  Returns how many accounts were re-assessed.
  """
  def sweep_unreachable do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@grace_days * 86_400, :second)

    ids =
      Repo.all(
        from(u in User,
          join: e in Email,
          on: e.user_id == u.id,
          where:
            u.email_confirmed? and is_nil(u.unreachable_at) and not is_nil(e.undeliverable_at) and
              e.undeliverable_at <= ^cutoff,
          distinct: true,
          select: u.id
        )
      )

    Enum.each(ids, &reassess_user/1)
    length(ids)
  end

  defp do_reassess(%User{} = user) do
    emails = Repo.all(from(e in Email, where: e.user_id == ^user.id))
    deliverable = Enum.filter(emails, &is_nil(&1.undeliverable_at))

    cond do
      deliverable != [] ->
        # The member can be reached again; lift a deliverability freeze if one
        # is in place (an address recovered, e.g. a new one was added).
        if user.unreachable_at, do: do_thaw(user, nil, %{"reason" => "address_recovered"})
        :ok

      is_nil(user.unreachable_at) and user.email_confirmed? and emails != [] and
          freeze_warranted?(user, emails) ->
        do_freeze(user, emails)

      true ->
        :ok
    end
  end

  # A confirmed account with no deliverable address is frozen once the failure
  # looks permanent: enough hard bounces, or one address dead past the grace
  # period.
  defp freeze_warranted?(%User{} = _user, emails) do
    hard_bounces_for(emails) >= @min_hard_bounces or dead_past_grace?(emails)
  end

  defp hard_bounces_for(emails) do
    addresses = Enum.map(emails, & &1.value)

    from(b in EmailBounce, where: b.email_value in ^addresses, select: b.status)
    |> Repo.all()
    |> Enum.count(&MailLog.recipient_failure?(&1 || ""))
  end

  defp dead_past_grace?(emails) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@grace_days, :day)

    Enum.any?(emails, fn e ->
      e.undeliverable_at && NaiveDateTime.compare(e.undeliverable_at, cutoff) != :gt
    end)
  end

  defp do_freeze(%User{} = user, emails) do
    now = NaiveDateTime.utc_now(:second)

    {_count, _} =
      from(u in User, where: u.id == ^user.id and is_nil(u.unreachable_at))
      |> Repo.update_all(set: [unreachable_at: now])

    reason = if dead_past_grace?(emails), do: "grace_period", else: "repeated_bounces"
    log("account_frozen", user_id: user.id, detail: %{"reason" => reason})
    {:ok, :frozen}
  end

  defp do_thaw(%User{} = user, actor_id, detail) do
    {_count, _} =
      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(set: [unreachable_at: nil])

    log("account_thawed", user_id: user.id, actor: actor_id, detail: detail)
    {:ok, :thawed}
  end

  @doc """
  Admin action: lift a deliverability freeze. Returns `{:ok, :thawed}` or
  `{:ok, :noop}` if the account was not frozen.
  """
  def thaw(%User{} = user, %User{admin?: true} = admin) do
    if user.unreachable_at do
      do_thaw(user, admin.id, %{"reason" => "admin"})
    else
      {:ok, :noop}
    end
  end

  @doc """
  Admin action: clear an address's undeliverable mark (delivery is believed to
  work again), then re-assess the owner so a freeze can lift.
  """
  def clear_address(%Email{} = email, %User{admin?: true} = admin) do
    Bounces.clear(email.value)

    log("address_recovered",
      user_id: email.user_id,
      email: email.value,
      actor: admin.id,
      detail: %{"reason" => "admin"}
    )

    if email.user_id, do: reassess_user(email.user_id)
    {:ok, :cleared}
  end

  ## Admin dashboard reads

  @doc "How many accounts are currently frozen for unreachability."
  def frozen_count do
    Repo.aggregate(from(u in User, where: not is_nil(u.unreachable_at)), :count)
  end

  @doc "Confirmed accounts currently frozen for unreachability, newest first."
  def frozen_accounts do
    Repo.all(
      from(u in User,
        where: not is_nil(u.unreachable_at),
        order_by: [desc: u.unreachable_at],
        preload: [:emails]
      )
    )
  end

  @doc "Addresses currently marked undeliverable, with their owner, newest first."
  def deactivated_addresses do
    Repo.all(
      from(e in Email,
        where: not is_nil(e.undeliverable_at),
        order_by: [desc: e.undeliverable_at],
        preload: [:user]
      )
    )
  end

  @doc "The most recent bounce-ledger rows."
  def recent_bounces(limit \\ 50) do
    Repo.all(from(b in EmailBounce, order_by: [desc: b.inserted_at], limit: ^limit))
  end

  @doc "The most recent deliverability events (freeze/thaw/deactivate/recover)."
  def recent_events(limit \\ 50) do
    Repo.all(from(ev in Event, order_by: [desc: ev.inserted_at], limit: ^limit))
  end

  @doc "All deliverability events for one member, oldest first (the audit timeline)."
  def events_for_user(user_id) do
    Repo.all(from(ev in Event, where: ev.user_id == ^user_id, order_by: [asc: ev.inserted_at]))
  end

  defp user_for_address(address) do
    Repo.one(from(u in User, join: e in assoc(u, :emails), where: e.value == ^address, limit: 1))
  end

  defp log(action, opts) do
    Repo.insert!(%Event{
      action: action,
      user_id: Keyword.get(opts, :user_id),
      email_value: Keyword.get(opts, :email),
      actor_id: Keyword.get(opts, :actor),
      detail: Keyword.get(opts, :detail, %{})
    })

    :ok
  end
end
