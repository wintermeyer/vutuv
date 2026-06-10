defmodule Vutuv.Moderation do
  @moduledoc """
  Content moderation: reports, the freezer and the strike ladder.

  Any member can report a post, a private message or a whole profile
  (`report_content/3`). A report from a reporter in good standing freezes the
  content immediately — it vanishes for everyone but the owner and admins —
  and opens a `Vutuv.Moderation.Case` that the owner can resolve without an
  admin: delete the content, edit it (auto-unfreezes) or dispute the report
  (escalates to the admin queue). Silence for #{72} hours escalates too, so
  admins only ever see disputes, ignored cases, re-reports and profile cases.

  Reports from reporters with a bad track record (`trusted_reporter?/1`)
  never freeze anything; they only flag the content for admin review. Whole
  profiles are never frozen by a single report — that takes a second,
  independent trusted reporter.

  Admin rulings: `uphold_case/2` confirms the violation and strikes the owner
  (warn → one-week suspension → permanent deactivation, strikes expire after
  a year); `reject_case/3` unfreezes and optionally marks reports as abusive,
  which strikes the *reporter* on the same ladder.

  All freeze state lives on the content rows (`frozen_at`), all account
  consequences on the user row (`suspended_until`, `deactivated_at`); the
  visibility chokepoints (`Vutuv.Posts.scope_visible/2`, `Vutuv.Chat`,
  `Vutuv.Search`, `VutuvWeb.Plug.EnsureActivated`) read them directly.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Chat.{Message, Participant}
  alias Vutuv.Moderation.{Case, Notifier, Report, Strike}
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  @owner_deadline_hours 72
  @strike_ttl_days 365
  @suspension_days 7
  @trust_window_days 365
  @rejected_reports_to_lose_trust 3
  @profile_freeze_reporters 2

  ## Reporting

  @doc """
  Files a report by `reporter` against `content` (a `%Post{}`, `%Message{}`
  or `%User{}` for a whole profile). `attrs` carries `"category"` (one of
  `Vutuv.Moderation.Report.categories/0`) and an optional `"note"`.

  Returns `{:ok, case}` or `{:error, :own_content | :not_allowed |
  :already_reported | changeset}`.
  """
  def report_content(%User{} = reporter, content, attrs) do
    # An open case means the content was already frozen by an earlier report;
    # the visibility check would now refuse everyone, but further reports on
    # an open case are wanted (they add weight), so the case wins.
    open = open_case_for(content)

    cond do
      owner_id(content) == nil -> {:error, :not_allowed}
      owner_id(content) == reporter.id -> {:error, :own_content}
      is_nil(open) and not reportable_by?(reporter, content) -> {:error, :not_allowed}
      is_nil(open) -> open_new_case(reporter, content, attrs)
      true -> join_case(open, reporter, content, attrs)
    end
  end

  defp open_new_case(reporter, content, attrs) do
    report_changeset = Report.changeset(%Report{reporter_id: reporter.id}, attrs)
    {status, effects} = initial_status(reporter, content)

    case_changeset =
      %Case{
        content_type: content_type(content),
        content_id: content_id(content),
        owner_id: owner_id(content),
        content_snapshot: snapshot(content)
      }
      |> Case.changeset(case_params(status))

    result =
      Repo.transaction(fn ->
        case_record = Repo.insert!(case_changeset)

        case Repo.insert(Ecto.Changeset.put_change(report_changeset, :case_id, case_record.id)) do
          {:ok, _report} -> case_record
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    with {:ok, case_record} <- result do
      if :freeze in effects, do: freeze_content(content)
      run_notifications(case_record, effects)
      {:ok, case_record}
    end
  end

  defp join_case(%Case{} = open, reporter, content, attrs) do
    report_changeset =
      Report.changeset(%Report{reporter_id: reporter.id, case_id: open.id}, attrs)

    case Repo.insert(report_changeset) do
      {:ok, _report} ->
        maybe_upgrade_case(open, reporter, content)

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :case_id),
          do: {:error, :already_reported},
          else: {:error, changeset}
    end
  end

  # A new report can upgrade an open case: a trusted report freezes a
  # so-far-only-flagged post/message, and the second trusted reporter
  # freezes a whole profile.
  defp maybe_upgrade_case(
         %Case{content_type: "user", status: "flagged"} = open,
         _reporter,
         content
       ) do
    reports = Repo.preload(open, reports: :reporter).reports

    trusted =
      Enum.reduce_while(reports, 0, fn report, count ->
        count = if trusted_reporter?(report.reporter), do: count + 1, else: count
        if count >= @profile_freeze_reporters, do: {:halt, count}, else: {:cont, count}
      end)

    if trusted >= @profile_freeze_reporters do
      freeze_content(content)
      updated = update_case!(open, case_params("escalated"))
      run_notifications(updated, [:notify_owner_review, :notify_admins_urgent])
      {:ok, updated}
    else
      {:ok, open}
    end
  end

  defp maybe_upgrade_case(%Case{status: "flagged"} = open, reporter, content) do
    if trusted_reporter?(reporter) do
      freeze_content(content)
      updated = update_case!(open, case_params("pending_owner"))
      run_notifications(updated, [:notify_owner_frozen])
      {:ok, updated}
    else
      {:ok, open}
    end
  end

  defp maybe_upgrade_case(open, _reporter, _content), do: {:ok, open}

  # The initial case status plus the side effects it implies.
  defp initial_status(_reporter, %User{}) do
    # Whole profiles are the nuclear option: the first report never freezes,
    # it lands in the admin queue marked urgent. See maybe_upgrade_case/3.
    {"flagged", [:notify_admins_urgent]}
  end

  defp initial_status(reporter, content) do
    cond do
      previously_self_resolved?(content) ->
        # The owner already used their one self-service round on this content;
        # a fresh report freezes it again and goes straight to the admins.
        {"escalated", [:freeze, :notify_owner_review]}

      trusted_reporter?(reporter) ->
        {"pending_owner", [:freeze, :notify_owner_frozen]}

      true ->
        {"flagged", []}
    end
  end

  defp case_params("pending_owner") do
    %{
      status: "pending_owner",
      owner_deadline_at:
        NaiveDateTime.add(NaiveDateTime.utc_now(:second), @owner_deadline_hours * 3600)
    }
  end

  defp case_params("escalated") do
    %{status: "escalated", escalated_at: NaiveDateTime.utc_now(:second), owner_deadline_at: nil}
  end

  defp case_params(status), do: %{status: status}

  defp run_notifications(case_record, effects) do
    if :notify_owner_frozen in effects, do: Notifier.owner_content_frozen(case_record)
    if :notify_owner_review in effects, do: Notifier.owner_under_review(case_record)
    if :notify_admins_urgent in effects, do: Notifier.admins_urgent(case_record)
    :ok
  end

  defp previously_self_resolved?(content) do
    from(c in Case,
      where:
        c.content_type == ^content_type(content) and
          c.content_id == ^content_id(content) and
          c.status == "resolved_edited"
    )
    |> Repo.exists?()
  end

  @doc """
  Whether this member's reports are taken at face value (instant freeze) or
  only flag content for admin review. Within the last year: any report an
  admin marked abusive kills trust, as do #{@rejected_reports_to_lose_trust}
  reports that admins rejected.
  """
  def trusted_reporter?(%User{id: user_id}) do
    %{abusive: abusive, rejected: rejected} =
      from(r in Report,
        join: c in assoc(r, :case),
        where: r.reporter_id == ^user_id,
        where: c.resolved_at > ^trust_window_start(),
        select: %{
          abusive: fragment("COUNT(*) FILTER (WHERE ?)", r.abusive?),
          rejected: fragment("COUNT(*) FILTER (WHERE ? = 'rejected')", c.status)
        }
      )
      |> Repo.one()

    trusted?(abusive, rejected)
  end

  defp trusted?(abusive, rejected),
    do: abusive == 0 and rejected < @rejected_reports_to_lose_trust

  defp trust_window_start do
    NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@trust_window_days * 86_400)
  end

  ## Cases

  @doc """
  One case with everything its pages need (owner, ruling admin, reports with
  reporters). Takes the raw params id; nil on garbage input or no such case.
  """
  def get_case_with_details(id) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil ->
        nil

      uuid ->
        Repo.one(
          from(c in Case,
            where: c.id == ^uuid,
            preload: [:owner, :resolved_by, reports: :reporter]
          )
        )
    end
  end

  @doc "The open case for this content item, if any."
  def open_case_for(content) do
    from(c in Case,
      where:
        c.content_type == ^content_type(content) and
          c.content_id == ^content_id(content) and
          c.status in ^Case.open_statuses()
    )
    |> Repo.one()
  end

  @doc "All open cases owned by `user` (for the owner's banner + case pages)."
  def open_cases_for_owner(%User{id: user_id}) do
    from(c in Case,
      where: c.owner_id == ^user_id and c.status in ^Case.open_statuses(),
      order_by: [desc: c.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  The cases whose owner was actually told about them (the content was frozen
  at some point: a self-service deadline or an escalation was set). Flag-only
  cases stay invisible to the owner, so a dismissed low-trust report never
  bothers them. `Vutuv.Activity` derives the owner's notification feed from
  this; it owns the rule so the feed cannot drift from the notify behavior.
  """
  def owner_notified_cases_query(user_id) do
    from(c in Case,
      where: c.owner_id == ^user_id,
      where: not is_nil(c.owner_deadline_at) or not is_nil(c.escalated_at)
    )
  end

  ## Owner self-service

  @doc """
  "My content is fine": the owner stands by the reported content. The case
  escalates to the admin queue; the content stays frozen until a human rules.
  """
  def dispute_case(%Case{} = case_record, %User{} = user) do
    cond do
      case_record.owner_id != user.id -> {:error, :not_allowed}
      case_record.status != "pending_owner" -> {:error, :not_open}
      true -> {:ok, update_case!(case_record, case_params("escalated"))}
    end
  end

  @doc """
  The owner's "delete the reported content" self-service action: deletes the
  content through its context (which settles the case) and owns the
  per-type dispatch, so controllers don't need to know which context deletes
  what. Profiles have no single deletable artifact — they are admin
  territory.

  Returns `:ok`, `{:error, :not_allowed}` (not the owner),
  `{:error, :not_deletable}` (a profile case) or `{:error, :already_deleted}`
  (the content is already gone).
  """
  def delete_reported_content(%Case{} = case_record, %User{} = user) do
    cond do
      case_record.owner_id != user.id ->
        {:error, :not_allowed}

      case_record.content_type == "user" ->
        {:error, :not_deletable}

      true ->
        case case_content(case_record) do
          nil ->
            {:error, :already_deleted}

          %Post{} = post ->
            # delete_post settles the case via the content_deleted hook (the
            # same path organic deletes through the post UI take).
            {:ok, _} = Posts.delete_post(post)
            :ok

          %Message{} = message ->
            {:ok, _} = Vutuv.Chat.delete_message(user, message)
            content_deleted(message)
        end
    end
  end

  @doc """
  Closes the open case (if any) because the owner deleted the content. Called
  from the deletion paths, so deleting reported content always settles its
  case without admin work.
  """
  def content_deleted(content) do
    case open_case_for(content) do
      nil ->
        :ok

      case_record ->
        update_case!(case_record, %{
          status: "resolved_deleted",
          resolved_at: NaiveDateTime.utc_now(:second)
        })

        :ok
    end
  end

  @doc """
  The owner edited reported content while its case was still in their court:
  the edit unfreezes it, closes the case and tells the reporters it was
  revised. A later re-report of the same content skips self-service and goes
  straight to the admins (see `report_content/3`). Edits during an escalated
  case change nothing — the case is with the admins.
  """
  def content_edited(content) do
    case open_case_for(content) do
      %Case{status: "pending_owner"} = case_record ->
        unfreeze_content(content)

        updated =
          update_case!(case_record, %{
            status: "resolved_edited",
            resolved_at: NaiveDateTime.utc_now(:second)
          })

        Notifier.reporters_content_revised(updated)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Escalates every pending_owner case whose 72h self-service deadline has
  passed. Returns the number of escalated cases. Called by the sweeper.
  """
  def escalate_overdue do
    now = NaiveDateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(c in Case, where: c.status == "pending_owner" and c.owner_deadline_at < ^now),
        set: [status: "escalated", escalated_at: now, updated_at: now]
      )

    count
  end

  ## Admin queue + rulings

  @doc "The admin queue: escalated cases first (oldest first), then flagged."
  def list_queue do
    from(c in Case,
      where: c.status in ["escalated", "flagged"],
      order_by: [
        asc: fragment("CASE WHEN ? = 'escalated' THEN 0 ELSE 1 END", c.status),
        asc: c.inserted_at
      ],
      preload: [:owner, reports: :reporter]
    )
    |> Repo.all()
  end

  @doc "How many cases wait for an admin (the badge + digest number)."
  def open_queue_count do
    Repo.aggregate(from(c in Case, where: c.status in ["escalated", "flagged"]), :count)
  end

  @doc """
  Admin ruling: the report was justified. The content stays frozen (a profile
  case unfreezes the profile — the strike ladder takes over there) and the
  owner gets a strike: warning, then a week's suspension, then permanent
  deactivation.
  """
  def uphold_case(%Case{} = case_record, %User{admin?: true} = admin) do
    updated =
      case_record
      |> Case.changeset(%{status: "upheld", resolved_at: NaiveDateTime.utc_now(:second)})
      |> Ecto.Changeset.put_change(:resolved_by_id, admin.id)
      |> Repo.update!()

    # For a profile case the consequence is the strike itself: a warning
    # leaves the profile visible again, a suspension/deactivation hides
    # everything anyway. Frozen posts/messages stay frozen as evidence.
    if case_record.content_type == "user" do
      set_user_moderation!(case_record.owner_id, frozen_at: nil)
    end

    owner =
      case case_record.owner do
        %User{} = preloaded -> preloaded
        _ -> Repo.get!(User, case_record.owner_id)
      end

    issue_strike(owner, updated, "owner", admin)

    {:ok, updated}
  end

  @doc """
  Admin ruling: the report was unfounded. Unfreezes the content and counts
  against every reporter's trust score. `abusive_report_ids` marks reports
  that were a deliberate weapon — each one strikes its *reporter* on the
  regular ladder.
  """
  def reject_case(%Case{} = case_record, %User{admin?: true} = admin, abusive_report_ids \\ []) do
    updated =
      case_record
      |> Case.changeset(%{status: "rejected", resolved_at: NaiveDateTime.utc_now(:second)})
      |> Ecto.Changeset.put_change(:resolved_by_id, admin.id)
      |> Repo.update!()

    # nil when the owner deleted the content mid-review: nothing to unfreeze.
    if content = case_content(case_record), do: unfreeze_content(content)

    abusive_reports =
      from(r in Report,
        where: r.case_id == ^case_record.id and r.id in ^abusive_report_ids,
        preload: :reporter
      )
      |> Repo.all()

    for report <- abusive_reports do
      report
      |> Ecto.Changeset.change(abusive?: true)
      |> Repo.update!()

      issue_strike(report.reporter, updated, "reporter", admin)
    end

    {:ok, updated}
  end

  ## Strikes

  @doc "Unexpired strikes against this member."
  def active_strike_count(%User{id: user_id}) do
    now = NaiveDateTime.utc_now(:second)

    Repo.aggregate(
      from(s in Strike, where: s.user_id == ^user_id and s.expires_at > ^now),
      :count
    )
  end

  # Strike + ladder consequence in one place. Strikes expire after a year, so
  # the count of *active* strikes decides the level.
  defp issue_strike(%User{} = user, %Case{} = case_record, role, %User{} = admin) do
    level = active_strike_count(user) + 1
    now = NaiveDateTime.utc_now(:second)

    %Strike{user_id: user.id, case_id: case_record.id, issued_by_id: admin.id}
    |> Strike.changeset(%{
      role: role,
      level: level,
      reason: "#{role}: case #{case_record.id}",
      expires_at: NaiveDateTime.add(now, @strike_ttl_days * 86_400)
    })
    |> Repo.insert!()

    apply_ladder(user, level, now)
  end

  defp apply_ladder(user, 1, _now) do
    Notifier.strike_warning(user)
  end

  defp apply_ladder(user, 2, now) do
    until = NaiveDateTime.add(now, @suspension_days * 86_400)
    set_user_moderation!(user.id, suspended_until: until)
    Notifier.suspension(user, until)
  end

  defp apply_ladder(user, _level, now) do
    set_user_moderation!(user.id, deactivated_at: now)
    Notifier.deactivation(user)
  end

  ## Reporter misuse tracking

  @doc "One reporter's track record: total reports, rejected ones, abusive marks."
  def reporter_stats(%User{id: user_id}) do
    Map.get(reporter_stats_map([user_id]), user_id, %{total: 0, rejected: 0, abusive: 0})
  end

  @doc """
  The track records of the given reporters in one query:
  `%{reporter_id => %{total:, rejected:, abusive:}}` (all-time counts, the
  numbers an admin sees next to each report).
  """
  def reporter_stats_map(reporter_ids) do
    from(r in Report,
      join: c in assoc(r, :case),
      where: r.reporter_id in ^reporter_ids,
      group_by: r.reporter_id,
      select:
        {r.reporter_id,
         %{
           total: count(r.id),
           rejected: fragment("COUNT(*) FILTER (WHERE ? = 'rejected')", c.status),
           abusive: fragment("COUNT(*) FILTER (WHERE ?)", r.abusive?)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The misuse dashboard: every member who has filed a report, with their track
  record and current trust standing, worst offenders first. The trusted flag
  is computed from the same windowed counts `trusted_reporter?/1` uses, in
  the one grouped query (no per-row lookups).
  """
  def list_reporter_stats do
    window_start = trust_window_start()

    from(r in Report,
      join: c in assoc(r, :case),
      join: u in User,
      on: u.id == r.reporter_id,
      group_by: u.id,
      order_by: [
        desc: fragment("COUNT(*) FILTER (WHERE ?)", r.abusive?),
        desc: fragment("COUNT(*) FILTER (WHERE ? = 'rejected')", c.status),
        desc: count(r.id)
      ],
      select: %{
        reporter: u,
        total: count(r.id),
        rejected: fragment("COUNT(*) FILTER (WHERE ? = 'rejected')", c.status),
        abusive: fragment("COUNT(*) FILTER (WHERE ?)", r.abusive?),
        recent_rejected:
          fragment(
            "COUNT(*) FILTER (WHERE ? = 'rejected' AND ? > ?)",
            c.status,
            c.resolved_at,
            type(^window_start, :naive_datetime)
          ),
        recent_abusive:
          fragment(
            "COUNT(*) FILTER (WHERE ? AND ? > ?)",
            r.abusive?,
            c.resolved_at,
            type(^window_start, :naive_datetime)
          )
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      row
      |> Map.put(:trusted, trusted?(row.recent_abusive, row.recent_rejected))
      |> Map.drop([:recent_rejected, :recent_abusive])
    end)
  end

  ## Account gates

  @doc """
  Whether this account may log in: `nil` (fine), `{:suspended, until}` or
  `:deactivated`.
  """
  def login_block(%User{deactivated_at: %NaiveDateTime{}}), do: :deactivated

  def login_block(%User{suspended_until: %NaiveDateTime{} = until}) do
    if NaiveDateTime.compare(until, NaiveDateTime.utc_now()) == :gt,
      do: {:suspended, until},
      else: nil
  end

  def login_block(_user), do: nil

  @doc """
  Whether this profile (and everything it owns) is hidden from other members:
  frozen pending review, currently suspended, or deactivated for good.
  """
  def account_hidden?(%User{} = user) do
    user.frozen_at != nil or user.deactivated_at != nil or login_block(user) != nil
  end

  ## Content plumbing

  defp content_type(%Post{}), do: "post"
  defp content_type(%Message{}), do: "message"
  defp content_type(%User{}), do: "user"

  defp content_id(%{id: id}), do: id

  defp owner_id(%Post{user_id: user_id}), do: user_id
  defp owner_id(%Message{sender_id: sender_id}), do: sender_id
  defp owner_id(%User{id: id}), do: id

  defp snapshot(%Post{body: body}), do: body
  defp snapshot(%Message{body: body}), do: body

  defp snapshot(%User{} = user) do
    [VutuvWeb.UserHelpers.full_name(user), user.headline]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # You can only report what you can see: posts via the visibility rules,
  # messages only as a participant of their conversation, profiles always.
  defp reportable_by?(reporter, %Post{} = post), do: Posts.visible_to?(post, reporter)

  defp reportable_by?(reporter, %Message{} = message) do
    Repo.exists?(
      from(p in Participant,
        where: p.conversation_id == ^message.conversation_id and p.user_id == ^reporter.id
      )
    )
  end

  defp reportable_by?(_reporter, %User{}), do: true

  defp freeze_content(content) do
    set_frozen_at(content, NaiveDateTime.utc_now(:second))

    # Open chat threads drop the message live; posts need no push (the read
    # paths filter on the next render).
    if match?(%Message{}, content), do: Vutuv.Chat.broadcast_message_frozen(content)
    :ok
  end

  defp unfreeze_content(content), do: set_frozen_at(content, nil)

  defp set_frozen_at(%Post{id: id}, value) do
    Repo.update_all(from(p in Post, where: p.id == ^id), set: [frozen_at: value])
  end

  defp set_frozen_at(%Message{id: id}, value) do
    Repo.update_all(from(m in Message, where: m.id == ^id), set: [frozen_at: value])
  end

  defp set_frozen_at(%User{id: id}, value) do
    set_user_moderation!(id, frozen_at: value)
  end

  defp set_user_moderation!(user_id, fields) do
    Repo.update_all(from(u in User, where: u.id == ^user_id), set: fields)
  end

  defp update_case!(%Case{} = case_record, params) do
    case_record
    |> Case.changeset(params)
    |> Repo.update!()
  end

  @doc "Loads the reported content row for a case (nil when deleted)."
  def case_content(%Case{content_type: type, content_id: id}), do: fetch_content(type, id)

  @doc """
  Loads a reportable content row by its wire form (`"post"` / `"message"` /
  `"user"` plus the raw params id) — the single home of the type→schema
  mapping the report flow and the case pages share. Nil on unknown types,
  garbage ids, or deleted content.
  """
  def fetch_content(type, id) do
    with schema when not is_nil(schema) <- content_schema(type),
         uuid when not is_nil(uuid) <- Vutuv.UUIDv7.cast_or_nil(id) do
      Repo.get(schema, uuid)
    else
      _ -> nil
    end
  end

  defp content_schema("post"), do: Post
  defp content_schema("message"), do: Message
  defp content_schema("user"), do: User
  defp content_schema(_), do: nil
end
