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
    # email_bounces.email_value and deliverability_events.email_value are both
    # varchar(255); a malformed/oversized parsed recipient must be sliced (like
    # `raw` below) so it stores cleanly instead of raising Postgres 22001.
    address = address |> String.downcase() |> String.slice(0, 255)
    now = NaiveDateTime.utc_now(:second)

    Repo.insert!(%EmailBounce{
      email_value: address,
      action: "failed",
      status: dsn,
      # A DSN diagnostic never needs 100 KB kept for forensics; bounding the
      # stored copy caps per-row storage so one report can't write a giant row
      # per recipient. The watcher's `raw` is a single short log line, well under
      # this, so it is unaffected.
      raw: String.slice(raw || "", 0, 16_000)
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

    from(b in EmailBounce, where: b.email_value in ^addresses, select: {b.status, b.raw})
    |> Repo.all()
    |> Enum.count(&confirmed_recipient_failure?/1)
  end

  # A ledger row proves a dead recipient only under the text-vetted classifier
  # (a generic 5.0.0 quota/blocked row recorded before the vetting existed must
  # not count toward a freeze).
  defp confirmed_recipient_failure?({status, raw}) do
    MailLog.recipient_failure?(status || "", raw || "")
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
  Data repair (run by the `RepairMisclassifiedBounceFreezes` migration, kept
  callable for ops): re-evaluates every address currently marked undeliverable
  against the text-vetted classifier and clears the mark when none of its
  ledger rows is a confirmed recipient failure - the generic-5.0.0
  misclassification, where full mailboxes (552 quota) and recipient-side
  blocks counted as dead recipients. Each owner is then re-assessed, so a
  freeze that rested only on misclassified bounces lifts, with the audit
  trail naming the repair. Idempotent. Returns `%{cleared: n, thawed: n}`.
  """
  def repair_misclassified_bounces do
    cleared =
      Repo.all(from(e in Email, where: not is_nil(e.undeliverable_at)))
      |> Enum.filter(&only_misclassified_bounces?/1)

    Enum.each(cleared, fn email ->
      Bounces.clear(email.value)

      log("address_recovered",
        user_id: email.user_id,
        email: email.value,
        detail: %{"reason" => "misclassified_bounce"}
      )
    end)

    owners = cleared |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    thawed =
      Enum.count(owners, fn user_id ->
        frozen_before? = frozen_now?(user_id)
        reassess_user(user_id)
        frozen_before? and not frozen_now?(user_id)
      end)

    %{cleared: length(cleared), thawed: thawed}
  end

  # An address qualifies for the repair only when there is ledger evidence and
  # none of it survives the vetted classifier. No evidence at all means the
  # mark came from elsewhere - leave it alone.
  defp only_misclassified_bounces?(%Email{value: value}) do
    case Repo.all(
           from(b in EmailBounce, where: b.email_value == ^value, select: {b.status, b.raw})
         ) do
      [] -> false
      rows -> not Enum.any?(rows, &confirmed_recipient_failure?/1)
    end
  end

  defp frozen_now?(user_id) do
    Repo.exists?(from(u in User, where: u.id == ^user_id and not is_nil(u.unreachable_at)))
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

  @doc """
  Per-day deliverability tallies for the operator's daily report: hard bounces
  recorded, and the address-deactivation / account-freeze / account-thaw
  transitions logged, in the half-open window `[start, stop)`.
  """
  def activity_between(%NaiveDateTime{} = start, %NaiveDateTime{} = stop) do
    %{
      bounces: count_in(EmailBounce, start, stop),
      deactivations: count_events("address_deactivated", start, stop),
      freezes: count_events("account_frozen", start, stop),
      thaws: count_events("account_thawed", start, stop)
    }
  end

  @doc """
  Capped sample rows behind `activity_between/2`, for the daily report's detail
  lists (up to `limit` rows per kind, oldest first). Bounces name the affected
  address and its status; deactivations the address; freezes and thaws also
  resolve the account owner (by `user_id`, a plain ledger value, not an
  association) so the report can link the member's profile — `user` is `nil`
  when the account is already gone.
  """
  def activity_details_between(%NaiveDateTime{} = start, %NaiveDateTime{} = stop, limit) do
    %{
      bounces:
        from(b in EmailBounce,
          where: b.inserted_at >= ^start and b.inserted_at < ^stop,
          order_by: [asc: b.inserted_at, asc: b.id],
          limit: ^limit,
          select: %{email: b.email_value, status: b.status}
        )
        |> Repo.all(),
      deactivations: event_sample("address_deactivated", start, stop, limit),
      freezes: event_sample("account_frozen", start, stop, limit),
      thaws: event_sample("account_thawed", start, stop, limit)
    }
  end

  defp count_in(schema, start, stop) do
    Repo.aggregate(
      from(r in schema, where: r.inserted_at >= ^start and r.inserted_at < ^stop),
      :count
    )
  end

  defp count_events(action, start, stop) do
    Repo.aggregate(
      from(ev in Event,
        where: ev.action == ^action and ev.inserted_at >= ^start and ev.inserted_at < ^stop
      ),
      :count
    )
  end

  # A capped, oldest-first sample of one event kind, each row carrying the
  # affected address and its (batch-resolved) owner for the daily report.
  defp event_sample(action, start, stop, limit) do
    events =
      Repo.all(
        from(ev in Event,
          where: ev.action == ^action and ev.inserted_at >= ^start and ev.inserted_at < ^stop,
          order_by: [asc: ev.inserted_at, asc: ev.id],
          limit: ^limit
        )
      )

    users = users_by_id(events)
    Enum.map(events, &%{email: &1.email_value, user: Map.get(users, &1.user_id)})
  end

  defp users_by_id(events) do
    case events |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> %{}
      ids -> from(u in User, where: u.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
    end
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
