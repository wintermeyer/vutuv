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

  A **copyright** complaint is the exception to the last two sentences: it is a
  legal notice, so it sits in the admin queue from the moment it is filed
  (`list_queue/0`) and an owner's edit does not settle it — it escalates
  instead (`content_edited/1`). Delete and dispute work as they do everywhere
  else. `Vutuv.Moderation.Report` refuses the category without the explanation
  and the reporter's good-faith declaration.

  A rights holder is usually **not a member** (issue #2009), so the same
  machinery is also reachable without an account, from `/system/report`:
  `file_public_notice/2` opens (or joins) the case as `flagged` and nothing
  else happens until the notifier follows the confirmation link in the receipt
  mail. `confirm_public_notice/1` is where the ordinary decision then runs —
  the freeze, the owner's notice, the urgent admin mail. Until then the notice
  counts for nothing anywhere (`Vutuv.Moderation.Report.effective?/1`), which
  is what stops five unconfirmed submissions from freezing a profile.

  Reports from reporters with a bad track record (`trusted_reporter?/1`)
  never freeze anything; they only flag the content for admin review. Whole
  profiles are never frozen by a single report — that takes a second,
  independent trusted reporter. An outside notifier climbs the same ladder by
  their **confirmed address** instead of by a user id.

  A **picture** is the one type where the category decides instead of the
  reporter (issue #2030): only a copyright notice takes it offline, house-rule
  complaints put it in front of an admin with the picture left where it is.
  Trust would decide nothing here, because a minutes-old account counts as
  trusted until a report of theirs has been rejected.

  Admin rulings: `uphold_case/2` confirms the violation and strikes the owner
  (warn → one-week suspension → permanent deactivation, strikes expire after
  a year); `reject_case/3` unfreezes and optionally marks reports as abusive,
  which strikes the *reporter* on the same ladder.

  All freeze state lives on the content rows (`frozen_at`), all account
  consequences on the user row (`suspended_until`, `deactivated_at`); the
  visibility chokepoints (`Vutuv.Posts.scope_visible/2`, `Vutuv.Chat`,
  `Vutuv.Search`, `VutuvWeb.Plug.EnsureActivated`) read them directly.

  A takedown here also leaves the building (issue #1102): freezing a post revokes
  the copies on other Fediverse servers (`Vutuv.Fediverse.revoke_post/1`) and
  lifting the freeze publishes it again, while a **permanent** account removal —
  `remove_owner/4` with `:deactivate`, and the strike ladder's third strike —
  broadcasts the actor `Delete` (`Vutuv.Fediverse.revoke_actor/1`). Everything
  temporary deliberately sends nothing: a week's suspension or a profile freeze
  must never tell the network an account is gone.
  """

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Chat.{Message, Participant}
  alias Vutuv.Fediverse
  alias Vutuv.Identity
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Jobs.JobPosting

  alias Vutuv.Moderation.{
    AdminAction,
    Case,
    Event,
    EvidenceScreenshot,
    Notifier,
    Report,
    Severance,
    Strike
  }

  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.Token

  @owner_deadline_hours 72
  @strike_ttl_days 365
  @suspension_days 7
  @trust_window_days 365
  @rejected_reports_to_lose_trust 3
  @profile_freeze_reporters 2
  # Spam auto-defense: this many *distinct* spam-category reports freeze a whole
  # profile pending admin review even when no single reporter is trusted (unlike
  # @profile_freeze_reporters, which needs two reporters in good standing). Kept
  # deliberately higher than the trusted bar so a small collusion ring can't
  # cheaply hide a rival — a wrongful freeze is low-harm (owner still sees their
  # own profile, admins are notified, reject_case restores everything and can
  # strike the brigaders' reports as abusive).
  @spam_freeze_reporters 5

  # How long a public notice's confirmation link is good for (issue #2009). A
  # link that never expires is a takedown anybody holding a forwarded copy of
  # that mail can set off a year later, and an unconfirmed row that is never
  # swept keeps a `flagged` case in the admin queue for ever. Long enough that
  # somebody who reads their mail on Monday is not locked out of their own
  # complaint.
  @notice_confirmation_days 7

  # The statuses an admin ruling may still act on; once a case is resolved
  # (upheld/rejected/resolved_*) a second ruling must be a no-op so it cannot
  # issue a second strike. Mirrors Case.open_statuses/0 as a compile-time list
  # usable in guards.
  @open_statuses Case.open_statuses()

  # The statuses that put a case in front of an admin on their own. A copyright
  # case joins the queue from any open status — see queue_query/0.
  @queue_statuses ~w(escalated flagged)

  ## Reporting

  @doc """
  Files a report by `reporter` against `content` (a `%Post{}`, `%Message{}`
  or `%User{}` for a whole profile). `attrs` carries `"category"` (one of
  `Vutuv.Moderation.Report.categories/0`) and an optional `"note"`.

  Returns `{:ok, case}` or `{:error, :own_content | :not_allowed |
  :already_reported | changeset}`.
  """
  def report_content(%User{} = reporter, content, attrs) do
    # The gate is `can_report?/2`, the one `ReportController.new` already asks —
    # see its `@doc` for why the open-case allowance has to be reporter-specific.
    # It also answers the missing-owner case, so there is no separate branch for
    # it here.
    open = open_case_for(content)

    cond do
      owner_id(content) == reporter.id -> {:error, :own_content}
      not can_report?(reporter, content, open) -> {:error, :not_allowed}
      is_nil(open) -> open_new_case(reporter, content, attrs)
      true -> join_case(open, reporter, content, attrs)
    end
  end

  @doc """
  Whether `reporter` may open the report flow for `content` — the gate the
  report form's `new` action shares with `report_content/3`, so the form never
  previews content (a private message, a restricted post) the reporter has no
  right to see. The owner must exist, and the reporter must currently be able to
  report it (visibility) or already be tied to it by an open case they filed a
  report on.

  The open-case arm must be reporter-specific: a mere *existing* open case is
  true for everyone, so keying the form on it alone let any logged-in member
  preview frozen/restricted/private content (whose permalink 404s for them) the
  moment a case was opened. A bystander with no report on the case falls through
  to the ordinary visibility check.
  """
  def can_report?(%User{} = reporter, content),
    do: can_report?(reporter, content, open_case_for(content))

  # The arity-3 twin exists so `report_content/3`, which has already loaded the
  # open case to decide what to do with it, does not read the same row twice.
  defp can_report?(%User{} = reporter, content, open) do
    owner_id(content) != nil and
      (reporter_on_open_case?(reporter, open) or reportable_by?(reporter, content))
  end

  # Whether `reporter` already filed a report on `content`'s open case. Being
  # tied to the case this way keeps the report form reachable (e.g. to file a
  # follow-up), but a case nobody else can see never opens the form to a
  # stranger who cannot otherwise view the content.
  defp reporter_on_open_case?(%User{id: reporter_id}, open) do
    case open do
      nil ->
        false

      %Case{id: case_id} ->
        Repo.exists?(
          from(r in Report, where: r.case_id == ^case_id and r.reporter_id == ^reporter_id)
        )
    end
  end

  defp open_new_case(reporter, content, attrs) do
    report_changeset =
      Report.changeset(%Report{reporter_id: reporter.id}, attrs, content_type(content))

    # Read off the changeset rather than out of `attrs`, so the answer does not
    # depend on whether the caller passed string or atom keys. A crafted
    # category buys nothing: the freeze runs only after the report insert
    # commits, and `Report.changeset/3` refuses a copyright notice without its
    # explanation and good-faith declaration.
    category = Ecto.Changeset.get_field(report_changeset, :category)
    {status, effects} = initial_status(reporter, content, category)

    case_changeset = new_case_changeset(content, status)

    case insert_case_with_report(case_changeset, report_changeset) do
      {:ok, {case_record, _report}} ->
        finish_new_case(case_record, reporter, content, category, effects)

      # Lost the race: a concurrent first-report already opened the case, so join
      # it instead of 500ing the losing reporter (the conflict means the winner
      # committed, so open_case_for finds it).
      {:error, :open_conflict} ->
        case open_case_for(content) do
          nil -> {:error, :not_allowed}
          open -> join_case(open, reporter, content, attrs)
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # A brand-new case for this content, at the status its first report earns.
  # Both ways in (a member's report, an outside notice) open a case the same
  # way; only when the decision runs differs.
  defp new_case_changeset(content, status) do
    %Case{
      content_type: content_type(content),
      content_id: content_id(content),
      owner_id: owner_id(content),
      content_snapshot: snapshot(content)
    }
    |> Case.changeset(case_params(status))
  end

  # The case + its first report in one transaction. A case insert can only fail
  # on the partial-unique open-case index (all its other fields are set
  # programmatically), so any case-insert error is the concurrent-first-report
  # conflict.
  defp insert_case_with_report(case_changeset, report_changeset) do
    Repo.transaction(fn ->
      case Repo.insert(case_changeset) do
        {:ok, case_record} -> insert_first_report(case_record, report_changeset)
        {:error, _changeset} -> Repo.rollback(:open_conflict)
      end
    end)
  end

  # Both rows come back, because the public path has to build its receipt mail
  # from the report as it was **stored** rather than from the values that were
  # typed.
  defp insert_first_report(case_record, report_changeset) do
    case Repo.insert(Ecto.Changeset.put_change(report_changeset, :case_id, case_record.id)) do
      {:ok, report} -> {case_record, report}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp finish_new_case(case_record, reporter, content, category, effects) do
    log(case_record, reporter, "report_filed", %{"category" => category})

    if :freeze in effects do
      freeze_content(content)
      log(case_record, nil, "content_frozen")
    end

    sever_relationship(case_record, reporter)
    # Evidence before cleanup: shoot the profile / conversation as it looks right
    # now (async; posts keep their text snapshot).
    EvidenceScreenshot.async_capture(case_record)
    run_notifications(case_record, effects)
    {:ok, case_record}
  end

  defp join_case(%Case{} = open, reporter, content, attrs) do
    report_changeset =
      Report.changeset(
        %Report{reporter_id: reporter.id, case_id: open.id},
        attrs,
        content_type(content)
      )

    case Repo.insert(report_changeset) do
      {:ok, report} ->
        log(open, reporter, "report_filed", %{"category" => report.category})
        result = maybe_upgrade_case(open, reporter, content, report.category)
        sever_relationship(open, reporter)
        result

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :case_id),
          do: {:error, :already_reported},
          else: {:error, changeset}
    end
  end

  ## The public notice (issue #2009)

  @doc """
  Files a report against `content` from somebody who has **no account here**.

  `attrs` carries the same `"category"` / `"note"` / `"good_faith?"` a member's
  report does, plus `"reporter_name"` and `"reporter_email"`; all five are
  required (`Report.outside_changeset/3`).

  Nothing is hidden and nobody is mailed about it yet. The case is opened (or
  joined) as `flagged`, which puts it in front of an admin and leaves the
  content exactly where it is; the decision the trust ladder would make waits
  for `confirm_public_notice/1`. Returns `{:ok, case, report, token}` — the
  token belongs in the receipt mail and is stored only as its SHA-256, and the
  **report** comes back because that mail must be built from the row as it was
  stored rather than from the values that were typed — or
  `{:error, :not_allowed | :already_reported | changeset}`.
  """
  def file_public_notice(content, attrs, locale \\ nil) do
    if owner_id(content) == nil do
      {:error, :not_allowed}
    else
      token = Token.random_token()

      changeset =
        %Report{
          confirmation_hash: Token.hash_token(token),
          confirmation_expires_at:
            NaiveDateTime.add(NaiveDateTime.utc_now(:second), @notice_confirmation_days * 86_400),
          # The language this notice is filed in, stored because both mails
          # about it are built later — the outcome one (issue #2011) inside
          # whichever admin's request settles the case, with no member row to
          # read a locale from. It is the caller's fact, not this context's: a
          # request locale is per-process web state.
          reporter_locale: locale
        }
        |> Report.outside_changeset(attrs, content_type(content))

      case open_case_for(content) do
        nil -> open_notice_case(content, changeset, token)
        open -> join_notice_case(open, changeset, token)
      end
    end
  end

  defp open_notice_case(content, report_changeset, token) do
    case_changeset = new_case_changeset(content, "flagged")

    case insert_case_with_report(case_changeset, report_changeset) do
      {:ok, {case_record, report}} ->
        # Actor nil: an outside notifier has no user row to name in the log,
        # and the report row itself carries who it was.
        log(case_record, nil, "notice_filed", %{"category" => report.category})
        {:ok, case_record, report, token}

      # Lost the race with a concurrent first report: the winner committed, so
      # the case is there to join now.
      {:error, :open_conflict} ->
        case open_case_for(content) do
          nil -> {:error, :not_allowed}
          open -> join_notice_case(open, report_changeset, token)
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp join_notice_case(%Case{} = open, report_changeset, token) do
    changeset = Ecto.Changeset.put_change(report_changeset, :case_id, open.id)

    case Repo.insert(changeset) do
      {:ok, report} ->
        log(open, nil, "notice_filed", %{"category" => report.category})
        {:ok, open, report, token}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :reporter_email),
          do: {:error, :already_reported},
          else: {:error, changeset}
    end
  end

  @doc """
  What the confirmation link's landing page is looking at: `:pending`,
  `:confirmed`, `:expired` or `:unknown`. A read, so the GET the link lands on
  changes nothing — the confirmation itself is the POST behind the button
  there.
  """
  def public_notice_state(token) when is_binary(token) and token != "" do
    # A tuple of two booleans, not the columns themselves: `select:
    # r.confirmed_at` answers `nil` for "no such token" and for "not confirmed
    # yet" alike, which are two of the answers this function exists to tell
    # apart.
    case Repo.one(
           from(r in Report,
             where: r.confirmation_hash == ^Token.hash_token(token),
             select:
               {not is_nil(r.confirmed_at),
                r.confirmation_expires_at < ^NaiveDateTime.utc_now(:second)}
           )
         ) do
      nil -> :unknown
      {true, _expired?} -> :confirmed
      {false, true} -> :expired
      {false, false} -> :pending
    end
  end

  def public_notice_state(_token), do: :unknown

  @doc """
  Follows the confirmation link from an outside notice's receipt mail.

  This is the moment the notice becomes real: the address is now known to
  belong to whoever typed it, so the report starts counting
  (`Report.effective?/1`), the ordinary decision runs — freeze where the
  category and the trust ladder allow one, tell the owner — and the admins get
  the urgent mail either way.

  Returns `{:ok, :confirmed, report}`, `{:ok, :already_confirmed, report}` (a
  second click is not an error), `{:error, :expired}` past the link's
  #{@notice_confirmation_days}-day deadline, or `{:error, :invalid}`.
  Deliberately claimed with one `UPDATE ... WHERE confirmed_at IS NULL AND
  confirmation_expires_at > now`, so two clicks in flight cannot run the side
  effects twice and a dead link cannot run them at all.
  """
  def confirm_public_notice(token) when is_binary(token) and token != "" do
    case claim_notice_confirmation(Token.hash_token(token)) do
      nil ->
        {:error, :invalid}

      {:expired, _report} ->
        {:error, :expired}

      {:already_confirmed, report} ->
        {:ok, :already_confirmed, report}

      {:confirmed, report} ->
        finish_confirmed_notice(report)
        {:ok, :confirmed, report}
    end
  end

  def confirm_public_notice(_token), do: {:error, :invalid}

  defp claim_notice_confirmation(hash) do
    now = NaiveDateTime.utc_now(:second)

    {_count, rows} =
      from(r in Report,
        where: r.confirmation_hash == ^hash and is_nil(r.confirmed_at),
        where: r.confirmation_expires_at > ^now,
        select: r
      )
      |> Repo.update_all(set: [confirmed_at: now, updated_at: now])

    case rows do
      [report] ->
        {:confirmed, report}

      # Nothing claimed: either the token names no row, or the row is already
      # confirmed, or its deadline has passed. Which of the three decides what
      # the page says, so ask rather than collapsing them into one error.
      [] ->
        case Repo.one(from(r in Report, where: r.confirmation_hash == ^hash)) do
          nil -> nil
          %Report{confirmed_at: %NaiveDateTime{}} = report -> {:already_confirmed, report}
          report -> {:expired, report}
        end
    end
  end

  defp finish_confirmed_notice(%Report{} = report) do
    case_record = Repo.get!(Case, report.case_id)
    log(case_record, nil, "notice_confirmed", %{"category" => report.category})

    # The evidence shot waits for the confirmation rather than riding the
    # submit: it launches headless Chromium, and an unauthenticated form must
    # not be a button that does that. Only when the case has none yet — a
    # notice joining a member's case must not re-shoot a page that already
    # changed since the first report.
    if is_nil(case_record.evidence_screenshot), do: EvidenceScreenshot.async_capture(case_record)

    {updated, admins_told?} = apply_confirmed_notice(case_record, report)
    unless admins_told?, do: Notifier.admins_urgent(updated)
    :ok
  end

  # The decision the submit deferred, applied to the case the notice already
  # opened. Returns the (possibly upgraded) case and whether the upgrade path
  # already mailed the admins, so the urgent mail is sent exactly once.
  #
  # Content deleted in the meantime has nothing to freeze, and a case already
  # frozen, escalated or resolved took its decision without this notice; both
  # leave the case as it stands, and the admins are still told.
  defp apply_confirmed_notice(%Case{status: "flagged"} = case_record, report) do
    case case_content(case_record) do
      nil -> {case_record, false}
      content -> decide_confirmed_notice(case_record, report, content)
    end
  end

  defp apply_confirmed_notice(case_record, _report), do: {case_record, false}

  defp decide_confirmed_notice(case_record, report, content) do
    case initial_status(report, content, report.category) do
      # This notice on its own hides nothing. The profile tally may still fire
      # (a second confirmed notice, or the spam threshold), and that path mails
      # the admins itself.
      {"flagged", _effects} ->
        {:ok, updated} = maybe_upgrade_case(case_record, report, content, report.category)
        {updated, updated.status != case_record.status}

      # `do_flagged_upgrade/4` freezes on its own, so the `:freeze` effect
      # `initial_status/3` returns is already accounted for here; what it takes
      # is the notification list.
      {status, effects} ->
        {:ok, updated} = do_flagged_upgrade(case_record, content, status, effects)
        {updated, false}
    end
  end

  # A new report can upgrade an open case: a trusted report freezes a
  # so-far-only-flagged post/message, and the second trusted reporter
  # freezes a whole profile. Exposed (@doc false) only so the concurrency
  # regression test can drive the upgrade twice with a stale flagged struct.
  @doc false
  def maybe_upgrade_case(
        %Case{content_type: type, status: "flagged"} = open,
        _reporter,
        content,
        _category
      )
      when type in ["user", "organization"] do
    # Only reports that count: a member's always does, an outside notice only
    # once its address is confirmed. Filtering here rather than in each tally
    # is the whole guard — an unconfirmed notice must not be able to freeze a
    # profile on its own or through the spam threshold.
    reports =
      open |> Repo.preload(:reports) |> Map.fetch!(:reports) |> Enum.filter(&Report.effective?/1)

    # Trust for every reporter of this case in ONE grouped windowed query per
    # kind, then tally in memory — never one trusted_reporter?/1 aggregate per
    # report (N+1).
    trusted = trusted_report_count(reports)

    # The spam auto-defense: enough distinct spam reports freeze the profile even
    # from untrusted reporters. Counting is a plain in-memory tally over the
    # already-loaded reports; distinctness comes from the two unique indexes on
    # the reports table, `(case_id, reporter_id)` for members and
    # `(case_id, reporter_email)` for outside notifiers — the second exists
    # because `(case_id, NULL)` never conflicts with itself in Postgres.
    spam = Enum.count(reports, &(&1.category == "spam"))

    if trusted >= @profile_freeze_reporters or spam >= @spam_freeze_reporters do
      do_flagged_upgrade(open, content, "escalated", [:notify_owner_review, :notify_admins_urgent])
    else
      {:ok, open}
    end
  end

  def maybe_upgrade_case(
        %Case{content_type: type, status: "flagged"} = open,
        reporter,
        content,
        category
      ) do
    if report_freezes?(type, category) and trusted_reporter?(reporter) do
      do_flagged_upgrade(open, content, "pending_owner", [:notify_owner_frozen])
    else
      {:ok, open}
    end
  end

  def maybe_upgrade_case(open, _reporter, _content, _category), do: {:ok, open}

  defp do_flagged_upgrade(open, content, new_status, effects) do
    case claim_flagged_upgrade(open, new_status) do
      {:ok, updated} ->
        freeze_content(content)
        log(updated, nil, "content_frozen")
        run_notifications(updated, effects)
        {:ok, updated}

      :already_upgraded ->
        {:ok, Repo.get!(Case, open.id)}
    end
  end

  # Atomically transitions a still-`flagged` case to `new_status`, claiming the
  # upgrade for exactly one caller. Two *different* reporters can race on the
  # same flagged case (the (case_id, reporter_id) unique index only stops the
  # same reporter from racing), but the `status == "flagged"` WHERE makes the
  # loser match zero rows, so the freeze/log/notify side effects run at most
  # once. The query twin of claim_case_resolution/3 for the upgrade path;
  # update_all does not touch timestamps, so updated_at is set explicitly.
  defp claim_flagged_upgrade(%Case{} = case_record, new_status) do
    now = NaiveDateTime.utc_now(:second)
    set = case_params(new_status) |> Map.put(:updated_at, now) |> Map.to_list()

    {_count, rows} =
      from(c in Case, where: c.id == ^case_record.id and c.status == "flagged", select: c)
      |> Repo.update_all(set: set)

    case rows do
      [updated] -> {:ok, updated}
      [] -> :already_upgraded
    end
  end

  # The initial case status plus the side effects it implies. What a report can
  # never hide lands in the admin queue marked urgent instead.
  defp initial_status(reporter, content, category) do
    if report_freezes?(content_type(content), category) do
      trust_based_status(reporter, content)
    else
      {"flagged", [:notify_admins_urgent]}
    end
  end

  # Whether a report of this category against this content type may take it
  # offline at all — asked once here and once in `maybe_upgrade_case/4`, so the
  # two ways into a freeze cannot answer it differently. It says *may*: a report
  # that passes here still has to come from a reporter in good standing.
  #
  # Whole profiles are the nuclear option, so the first report never freezes one;
  # that takes a second trusted reporter (or the spam threshold) in
  # `maybe_upgrade_case/4`. An organization page is profile-style for the same
  # reason.
  defp report_freezes?(type, _category) when type in ["user", "organization"], do: false

  # A picture is the third thing a single report does not hide, and here the
  # category decides rather than the reporter (issue #2030). `trusted_reporter?/1`
  # trusts an account created a minute ago — nothing of theirs has been rejected
  # yet — so before this split one throwaway account took any member's avatar off
  # every surface with its first ever report, and two of them would have done it
  # through the upgrade path. A copyright notice keeps the instant reach: it is
  # the legal claim the machinery was built for and the only category that
  # already demands a written explanation and a good-faith declaration. A
  # house-rule complaint goes in front of an admin instead, with the picture left
  # where it is, exactly as a report against a whole profile does.
  defp report_freezes?("image", category), do: Report.copyright?(category)

  defp report_freezes?(_type, _category), do: true

  defp trust_based_status(reporter, content) do
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
  Whether this reporter's reports are taken at face value (instant freeze) or
  only flag content for admin review. Within the last year: any report an
  admin marked abusive kills trust, as do #{@rejected_reports_to_lose_trust}
  reports that admins rejected.

  Takes a `%User{}` for a member, or a whole `%Report{}` — which is how the
  outside path asks it (issue #2009): a member's report is judged by their user
  id, a confirmed outside notice by its address, and an unconfirmed one is
  never trusted, nothing having verified that the person who typed the address
  can read it.
  """
  def trusted_reporter?(reporter)

  def trusted_reporter?(%User{id: user_id}) do
    MapSet.member?(trusted_reporter_ids([user_id]), user_id)
  end

  def trusted_reporter?(%Report{reporter_id: user_id}) when is_binary(user_id),
    do: MapSet.member?(trusted_reporter_ids([user_id]), user_id)

  def trusted_reporter?(%Report{confirmed_at: %NaiveDateTime{}, reporter_email: email})
      when is_binary(email),
      do: MapSet.member?(trusted_reporter_emails([email]), email)

  def trusted_reporter?(%Report{}), do: false

  # How many of `reports` come from a reporter in good standing — two grouped
  # queries, one per kind of reporter, never one aggregate per report.
  #
  # The reporter ids and the addresses are collected in NAMED functions rather
  # than inline, because this is the list that must never carry a nil: the
  # column is nullable now, and `r.reporter_id in (NULL, …)` is never true for
  # a NULL row, so a nil that slipped through would fall out of the query with
  # no stats row at all and read back as {0, 0} — i.e. as *trusted*. Two
  # unconfirmed strangers would then have frozen any profile.
  defp trusted_report_count(reports) do
    trusted_ids = reports |> member_reporter_ids() |> trusted_reporter_ids()
    trusted_emails = reports |> outside_reporter_emails() |> trusted_reporter_emails()

    Enum.count(reports, fn
      %Report{reporter_id: id} when is_binary(id) -> MapSet.member?(trusted_ids, id)
      %Report{reporter_email: email} -> MapSet.member?(trusted_emails, email)
    end)
  end

  defp member_reporter_ids(reports) do
    for %Report{reporter_id: id} <- reports, is_binary(id), do: id
  end

  defp outside_reporter_emails(reports) do
    for %Report{reporter_id: nil, reporter_email: email} <- reports, is_binary(email), do: email
  end

  defp trusted_reporter_ids(reporter_ids), do: trusted_reporters(:reporter_id, reporter_ids)
  defp trusted_reporter_emails(emails), do: trusted_reporters(:reporter_email, emails)

  # The subset of `keys` whose reports are trusted (`trusted?/2`), computed in
  # one grouped windowed query (the COUNT(*) FILTER shape `list_reporter_stats/0`
  # uses) so a profile-freeze check never runs a per-reporter aggregate (N+1). A
  # reporter with no resolved-in-window report has no row and defaults to
  # {0, 0} — trusted, exactly like `trusted_reporter?/1` returns for an empty
  # aggregate.
  #
  # `column` is the id or the address (issue #2009): a member is judged by their
  # user row, an outside notifier by the address they confirmed. Only
  # `effective` reports count either way, which for a member is every one of
  # them and for a notifier only a confirmed one — an unconfirmed notice has
  # neither earned trust nor lost any.
  defp trusted_reporters(_column, []), do: MapSet.new()

  defp trusted_reporters(column, keys) do
    stats =
      from(r in Report,
        join: c in assoc(r, :case),
        where: field(r, ^column) in ^keys,
        where: c.resolved_at > ^trust_window_start(),
        group_by: field(r, ^column),
        select: {
          field(r, ^column),
          fragment("COUNT(*) FILTER (WHERE ?)", r.abusive?),
          fragment("COUNT(*) FILTER (WHERE ? = 'rejected')", c.status)
        }
      )
      |> Report.effective()
      |> Repo.all()
      |> Map.new(fn {key, abusive, rejected} -> {key, {abusive, rejected}} end)

    keys
    |> Enum.filter(fn key ->
      {abusive, rejected} = Map.get(stats, key, {0, 0})
      trusted?(abusive, rejected)
    end)
    |> MapSet.new()
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
    Vutuv.UUIDv7.with_cast(id, fn uuid ->
      Repo.one(
        from(c in Case,
          where: c.id == ^uuid,
          preload: [:owner, :resolved_by, reports: :reporter]
        )
      )
    end)
  end

  @doc """
  The case row on its own, no preloads. Same contract as
  `get_case_with_details/1` — raw params id in, nil on garbage input or no such
  case — for the one page that needs the row and nothing hanging off it
  (`VutuvWeb.ModerationCaseController.image/2`, which only asks what content
  type the case is about).

  Beside its fuller twin rather than a `Repo.get` in the controller: "a raw id
  becomes a case, or nothing" is one rule, and a controller spelling it itself
  read the id straight, where a malformed one raises rather than missing —
  a 400 and an exception in the log for a wrong address (issue #2031).
  """
  def get_case(id), do: Vutuv.UUIDv7.with_cast(id, &Repo.get(Case, &1))

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
      case_record.owner_id != user.id ->
        {:error, :not_allowed}

      case_record.status != "pending_owner" ->
        {:error, :not_open}

      true ->
        updated = update_case!(case_record, case_params("escalated"))
        log(updated, user, "owner_disputed")
        {:ok, updated}
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

      case_record.content_type in ["user", "organization"] ->
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

          %JobPosting{} = posting ->
            # delete_job_posting settles the case via the content_deleted hook,
            # the same path an organic delete takes.
            {:ok, _} = Vutuv.Jobs.delete_job_posting(posting)
            :ok

          # "Remove it" for a picture: the copies and the private original go,
          # held or not (a report that only flagged the picture never moved
          # anything). There is no edit offer to sit beside this — a picture
          # cannot be revised, only taken down or disputed.
          %Image{} = image ->
            :ok = Images.purge(image)
            content_deleted(image)
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
        updated =
          update_case!(case_record, %{
            status: "resolved_deleted",
            resolved_at: NaiveDateTime.utc_now(:second)
          })

        log(updated, nil, "content_deleted")
        Notifier.reporters_case_closed(updated)
        :ok
    end
  end

  @doc """
  What a reporter is told a closed case ended in — `Case.reporter_outcome/1`,
  re-exported here because `Vutuv.Moderation` is the context every caller
  outside this directory already talks to.
  """
  defdelegate reporter_outcome(status), to: Case

  @doc """
  The owner edited reported content while its case was still in their court:
  the edit unfreezes it, closes the case and tells the reporters it was
  revised. A later re-report of the same content skips self-service and goes
  straight to the admins (see `report_content/3`). Edits during an escalated
  case change nothing — the case is with the admins.

  A copyright complaint is the exception: the claim is that the work was never
  the owner's to publish, and no rewrite settles that. The edit is recorded,
  the content stays hidden and the case escalates for a human to check.
  """
  def content_edited(content) do
    case open_case_for(content) do
      %Case{status: "pending_owner"} = case_record ->
        # `copyright_case?/1` reads them; nothing else here does. `:reports`
        # alone, never `reports: :reporter` — a report is anonymous, and the
        # reporters' notice looks itself up from the case id.
        case_record = Repo.preload(case_record, :reports)

        if copyright_case?(case_record),
          do: hand_edit_to_admins(case_record),
          else: resolve_edited(content, case_record)

      _ ->
        :ok
    end
  end

  defp resolve_edited(content, %Case{} = case_record) do
    unfreeze_content(content)

    updated =
      update_case!(case_record, %{
        status: "resolved_edited",
        resolved_at: NaiveDateTime.utc_now(:second)
      })

    log(updated, nil, "content_edited")
    Notifier.reporters_case_closed(updated)
    :ok
  end

  # No unfreeze and no "revised" notice: the reporters' claim is about the
  # work, not about its wording. The case was already in the queue, so this
  # only moves it to the front of it, with the edit in the History timeline
  # the admin reads.
  defp hand_edit_to_admins(%Case{} = case_record) do
    updated = update_case!(case_record, case_params("escalated"))
    log(updated, nil, "content_edited")
    :ok
  end

  @doc """
  Escalates every pending_owner case whose 72h self-service deadline has
  passed. Returns the number of escalated cases. Called by the sweeper.
  """
  def escalate_overdue do
    now = NaiveDateTime.utc_now(:second)

    # RETURNING the ids the UPDATE actually changed (one atomic statement)
    # rather than a separate SELECT then UPDATE: otherwise a case that leaves
    # pending_owner in the gap between the two gets a bogus 'escalated_deadline'
    # event and the logged count diverges from the events written.
    {_count, ids} =
      from(c in Case,
        where: c.status == "pending_owner" and c.owner_deadline_at < ^now,
        select: c.id
      )
      |> Repo.update_all(set: [status: "escalated", escalated_at: now, updated_at: now])

    for id <- ids, do: Repo.insert!(%Event{case_id: id, action: "escalated_deadline"})

    length(ids)
  end

  @doc """
  Drops every public notice whose confirmation deadline has passed without
  anybody following the link, and resolves the cases that were only standing
  because of one. Returns the number of notices deleted. Called by the sweeper.

  Without it an unconfirmed notice is a permanent `flagged` row in the admin
  queue that nothing can ever act on: it counts for nothing
  (`Report.effective?/1`), its link no longer works, and no ruling makes sense
  on a claim nobody stood behind. A case that still holds another report keeps
  standing; one left with none is settled `rejected`, which is what "nobody
  ever confirmed this" means and what puts the content back if anything about
  it had moved.
  """
  def sweep_expired_notices do
    now = NaiveDateTime.utc_now(:second)

    {_count, case_ids} =
      from(r in Report,
        where: is_nil(r.confirmed_at) and r.confirmation_expires_at < ^now,
        select: r.case_id
      )
      |> Repo.delete_all()

    for case_id <- Enum.uniq(case_ids), do: settle_abandoned_case(case_id)
    length(case_ids)
  end

  # A case whose last report was an expired notice. Only ever reached from the
  # sweep above, and only for a case that is still open — an admin who ruled in
  # the meantime keeps their ruling.
  defp settle_abandoned_case(case_id) do
    with %Case{status: status} = case_record when status in @open_statuses <-
           Repo.get(Case, case_id),
         false <- Repo.exists?(from(r in Report, where: r.case_id == ^case_id)) do
      if content = case_content(case_record), do: unfreeze_content(content)

      updated =
        update_case!(case_record, %{
          status: "rejected",
          resolved_at: NaiveDateTime.utc_now(:second)
        })

      log(updated, nil, "notice_expired")
      :ok
    else
      _ -> :ok
    end
  end

  ## Admin queue + rulings

  @doc "The admin queue: escalated cases first (oldest first), then flagged."
  def list_queue do
    queue_query()
    |> order_by([c],
      asc: fragment("CASE WHEN ? = 'escalated' THEN 0 ELSE 1 END", c.status),
      asc: c.inserted_at
    )
    |> preload([:owner, reports: :reporter])
    |> Repo.all()
  end

  @doc "How many cases wait for an admin (the badge + digest number)."
  def open_queue_count do
    Repo.aggregate(queue_query(), :count)
  end

  # An ordinary frozen case spends its first 72 hours with its owner and only
  # reaches an admin if the deadline passes or the owner disputes. A copyright
  # complaint is a legal notice and cannot wait that long, so it joins the queue
  # in any open status while the owner keeps their self-service window.
  defp queue_query do
    from(c in Case,
      as: :case,
      where: c.status in ^@open_statuses,
      where:
        c.status in ^@queue_statuses or
          exists(subquery(where(copyright_reports(), [r], r.case_id == parent_as(:case).id)))
    )
  end

  defp copyright_reports do
    from(r in Report, where: r.category == ^Report.copyright_category())
  end

  @doc """
  Whether this case carries a copyright complaint. Takes the preloaded reports
  if they are there and looks them up if they are not, so the answer never
  depends on whether the caller remembered a preload.

  Only **effective** reports count, and the filter is inside both clauses
  rather than at the call sites, because this answer decides what the owner may
  do with their own content: `owner_edit_offer/2` turns an edit from
  "immediate" into "reviewed" on it, and `content_edited/1` escalates instead
  of unfreezing. An unconfirmed notice from a stranger was enough to take a
  member's self-service away — the case page is the one surface that must still
  see a pending notice, and it reads the reports itself.
  """
  def copyright_case?(%Case{reports: reports}) when is_list(reports),
    do: reports |> Enum.filter(&Report.effective?/1) |> Enum.any?(&Report.copyright?/1)

  def copyright_case?(%Case{id: case_id}) do
    copyright_reports()
    |> where([r], r.case_id == ^case_id)
    |> Report.effective()
    |> Repo.exists?()
  end

  @doc """
  Whether a copyright notice was filed on this case but **counts for nothing
  yet** — an outside notice whose address nobody has confirmed
  (`Report.effective?/1`).

  It exists because that state reads on the admin case page as its own
  opposite: the picture is still on the profile, `copyright_case?/1` says no,
  and the page then explained the picture with "only a copyright notice takes
  one offline before a ruling" — on a case whose category is copyright. The
  reason is the unconfirmed address, and only this predicate can tell the two
  apart. Takes the case with its **plain** `:reports` preload, which is what
  the two admin surfaces carry.
  """
  def pending_copyright_notice?(%Case{reports: reports} = case_record) when is_list(reports),
    do: Enum.any?(reports, &Report.copyright?/1) and not copyright_case?(case_record)

  def pending_copyright_notice?(%Case{} = case_record),
    do: case_record |> Repo.preload(:reports) |> pending_copyright_notice?()

  @doc """
  What became of the reported content itself, for the notice its reporter is
  owed (issues #2011/#2067): `:removed`, `:hidden` or `:visible`.

  **Measured after the ruling settled the content**, never derived from the
  case status — one `"upheld"` ends three different ways (a picture is purged,
  a post stays frozen as evidence, a profile comes back with its owner on the
  strike ladder), and the sweeping "we have taken the necessary steps" the mail
  used to send instead is exactly the sentence that made the notice worthless.
  Every caller runs after `settle_content_on_uphold/1` or `unfreeze_content/1`,
  so what it reads is the answer.

  A hidden owner hides everything they own, so a suspended or deactivated
  account counts as `:hidden` even when the content row itself was never
  frozen — otherwise the account removal an admin has just carried out would be
  reported to the reporter as "still visible".
  """
  def reported_content_fate(%Case{} = case_record) do
    case case_content(case_record) do
      nil -> :removed
      content -> if content_hidden?(case_record, content), do: :hidden, else: :visible
    end
  end

  # A profile case's content *is* its owner (`owner_id/1` on a `%User{}` returns
  # its own id), so reading the row a second time would be the same row —
  # and `account_hidden?/1` already tests `frozen_at`.
  defp content_hidden?(%Case{owner_id: id}, %User{id: id} = owner), do: account_hidden?(owner)

  defp content_hidden?(%Case{}, %{frozen_at: %NaiveDateTime{}}), do: true

  defp content_hidden?(%Case{owner_id: owner_id}, _content) do
    case Repo.get(User, owner_id) do
      nil -> true
      owner -> account_hidden?(owner)
    end
  end

  @doc """
  What upholding this case would do to the content, for the admin about to
  rule: `:deleted`, `:stays_hidden`, `:untouched` or `:unhidden`.

  The decision panel promised "the content stays hidden" on every case, which
  is true for a frozen post and false for the three other shapes an open case
  has: a picture is deleted by the ruling whether or not it was ever hidden, a
  flagged post was never hidden in the first place, and an upheld **profile**
  case unfreezes the profile because the consequence there is the strike.

  It is the *description* of what `settle_content_on_uphold/1` does, so the two
  clause lists have to move together; content that is gone falls through to
  `:untouched`, which is the honest answer for a ruling that no longer has
  anything to act on.
  """
  def uphold_content_effect(%Case{content_type: "image"}, _content), do: :deleted

  def uphold_content_effect(%Case{content_type: type}, %{frozen_at: %NaiveDateTime{}})
      when type in ["user", "organization"],
      do: :unhidden

  def uphold_content_effect(%Case{}, %{frozen_at: %NaiveDateTime{}}), do: :stays_hidden
  def uphold_content_effect(%Case{}, _content), do: :untouched

  @doc """
  The statement of reasons the owner of hidden content is owed (issue #2010):
  what was claimed, in the words the reporters typed, and on what ground.

  `categories` are the wire strings, deduplicated, most recent report first;
  `notes` are the explanations, blanks dropped; `copyright?` says whether the
  ground is the law rather than the house rules. The reporter is deliberately
  not in the map — reports are anonymous, and a surface cannot leak what it
  was never handed.

  `from_member?` is the one thing about the reporter the owner does get, and
  only because the alternative was a lie: both owner surfaces explained the
  automatic freeze as "a report from a **member** in good standing", which for
  an outside notice (issue #2009) names somebody who does not exist and points
  the owner at the wrong people. It says whether *any* effective report on this
  case has an account here, never which one, so a case a member and a stranger
  both reported keeps the member wording it has earned.

  All three surfaces that carry the notice (the case page, the owner's email
  and the in-app line) read it here, so they cannot drift apart.

  Only **effective** reports are in it, filtered inside rather than by each
  caller: this is the map that quotes a reporter's words to the member they
  accuse, and an unconfirmed notice is a stranger's unverified claim that
  nothing about the case has acted on. The DB clause preloads through
  `effective_reports/0`, so the text is not even loaded.
  """
  def owner_notice(%Case{reports: reports}) when is_list(reports) do
    ordered =
      reports
      |> Enum.filter(&Report.effective?/1)
      |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})

    categories = ordered |> Enum.map(& &1.category) |> Enum.uniq()

    %{
      categories: categories,
      category: leading_category(categories),
      notes: ordered |> Enum.map(& &1.note) |> Enum.reject(&(&1 in [nil, ""])),
      copyright?: Enum.any?(categories, &Report.copyright?/1),
      from_member?: Enum.any?(ordered, &is_binary(&1.reporter_id))
    }
  end

  def owner_notice(%Case{} = case_record),
    do: case_record |> Repo.preload(reports: effective_reports()) |> owner_notice()

  @doc """
  The preload to use wherever a case's reports drive what happens to the
  content or reach its owner — `Repo.preload(case, reports: effective_reports())`.

  The plain `:reports` preload stays right for the two admin surfaces, which
  have to see a notice whose address nobody has confirmed yet; everything else
  wants this one, so a stranger's unverified words cannot be loaded into a mail
  or a decision by whoever forgot.
  """
  def effective_reports, do: Report.effective(Report)

  @doc """
  What the owner's self-service round offers as an *edit*, as one value the
  surfaces render instead of deriving: `:immediate` (an edit brings the content
  straight back), `:reviewed` (a copyright claim, so an admin looks at the
  revision and the content stays hidden until they have) or `:none`.

  Only a post has an editor behind the case page's button, so a reported
  message or job posting is offered delete and dispute alone. Answered here
  rather than recombined from two booleans in each of the seven places that
  render the options, so no locale can promise a copyright case its content
  back.
  """
  def owner_edit_offer(%Case{content_type: "post"} = case_record, %Post{}),
    do: if(copyright_case?(case_record), do: :reviewed, else: :immediate)

  def owner_edit_offer(%Case{}, _content), do: :none

  @doc """
  The same answer for a caller that does not already hold the content — the
  email path. Looks the post up only when the type could have an editor at all.
  """
  def owner_edit_offer(%Case{content_type: "post"} = case_record),
    do: owner_edit_offer(case_record, case_content(case_record))

  def owner_edit_offer(%Case{}), do: :none

  @doc """
  The one category to name per case id — what the in-app notification line, the
  one place with room for a single word, says was claimed. Returns a
  `case_id => category` map; a case whose reports are gone is absent.
  """
  def notice_category_by_case([]), do: %{}

  def notice_category_by_case(case_ids) when is_list(case_ids) do
    # Ordered in SQL, and `Enum.group_by/3` keeps that order inside each group,
    # so `leading_category/1` sees the same "most recent first" list the
    # single-case `owner_notice/1` builds.
    from(r in Report,
      where: r.case_id in ^case_ids,
      order_by: [desc: r.inserted_at],
      select: {r.case_id, r.category}
    )
    |> Report.effective()
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {case_id, categories} -> {case_id, leading_category(categories)} end)
  end

  # A copyright notice wins over anything else on the same case — it is the one
  # with legal weight — otherwise the most recent report speaks.
  defp leading_category(categories),
    do: Enum.find(categories, &Report.copyright?/1) || List.first(categories)

  @doc """
  How many open cases (any open status: frozen-pending-owner, flagged or
  escalated) exist for a content type — the per-area tile figure (e.g. the
  `/admin/jobs` "open job-related moderation cases" count for `"job_posting"`).
  """
  def open_case_count(content_type) when is_binary(content_type) do
    Repo.aggregate(
      from(c in Case,
        where: c.content_type == ^content_type and c.status in ^Case.open_statuses()
      ),
      :count
    )
  end

  @doc "How many open cases of `content_type` are owned by `owner_id` (the member footprint)."
  def owner_open_case_count(owner_id, content_type) do
    Repo.aggregate(
      from(c in Case,
        where:
          c.owner_id == ^owner_id and c.content_type == ^content_type and
            c.status in ^Case.open_statuses()
      ),
      :count
    )
  end

  @doc """
  Every case ever opened against one content item (open and resolved), newest
  first, with reports preloaded — the report history the admin detail drawers
  show. Takes the content's wire type + id.
  """
  def cases_for_content(content_type, content_id) do
    from(c in Case,
      where: c.content_type == ^content_type and c.content_id == ^content_id,
      order_by: [desc: c.inserted_at],
      preload: [:reports]
    )
    |> Repo.all()
  end

  @doc """
  Admin ruling: the report was justified. The content stays frozen (a profile
  case unfreezes the profile — the strike ladder takes over there) and the
  owner gets a strike: warning, then a week's suspension, then permanent
  deactivation.
  """
  def uphold_case(%Case{} = case_record, %User{admin?: true} = admin) do
    case claim_case_resolution(case_record, "upheld", admin) do
      :already_resolved ->
        {:error, :not_open}

      {:ok, updated} ->
        # For a profile case the consequence is the strike itself: a warning
        # leaves the profile visible again, a suspension/deactivation hides
        # everything anyway. Frozen posts/messages stay frozen as evidence. A
        # organization case unfreezes the page (the strike lands on its owner member).
        settle_content_on_uphold(case_record)

        owner =
          case case_record.owner do
            %User{} = preloaded -> preloaded
            _ -> Repo.get!(User, case_record.owner_id)
          end

        log(updated, admin, "upheld")
        issue_strike(owner, updated, "owner", admin)
        Notifier.reporters_case_closed(updated)

        {:ok, updated}
    end
  end

  defp settle_content_on_uphold(%Case{content_type: "user", owner_id: owner_id}) do
    set_user_moderation!(owner_id, frozen_at: nil)
  end

  defp settle_content_on_uphold(%Case{content_type: "organization"} = case_record) do
    case case_content(case_record) do
      %Organization{} = organization -> unfreeze_content(organization)
      _ -> :ok
    end
  end

  # An upheld picture is the one content type the ruling itself removes. A post
  # stays frozen as evidence, but the whole claim about a picture is that these
  # bytes may not be here, so the held copies and the private original go
  # (issue #2012). The case keeps its snapshot and its history.
  defp settle_content_on_uphold(%Case{content_type: "image"} = case_record) do
    case case_content(case_record) do
      %Image{} = image -> Images.purge(image)
      _ -> :ok
    end
  end

  defp settle_content_on_uphold(_case_record), do: :ok

  # Atomically transitions a still-open case to its resolved status, claiming
  # it for exactly one caller. The `status in @open_statuses` WHERE makes a
  # second ruling (a double-submit or a second admin holding a stale struct)
  # match zero rows, so the strike-issuing consequences run at most once.
  defp claim_case_resolution(%Case{} = case_record, status, %User{} = admin) do
    now = NaiveDateTime.utc_now(:second)

    {_count, rows} =
      from(c in Case, where: c.id == ^case_record.id and c.status in ^@open_statuses, select: c)
      |> Repo.update_all(
        set: [status: status, resolved_at: now, resolved_by_id: admin.id, updated_at: now]
      )

    case rows do
      [updated] -> {:ok, updated}
      [] -> :already_resolved
    end
  end

  @doc """
  Admin ruling: the report was unfounded. Unfreezes the content and counts
  against every reporter's trust score. `abusive_report_ids` marks reports
  that were a deliberate weapon — each one strikes its *reporter* on the
  regular ladder.
  """
  def reject_case(%Case{} = case_record, %User{admin?: true} = admin, abusive_report_ids \\ []) do
    case claim_case_resolution(case_record, "rejected", admin) do
      :already_resolved ->
        {:error, :not_open}

      {:ok, updated} ->
        log(updated, admin, "rejected")

        # nil when the owner deleted the content mid-review: nothing to unfreeze.
        if content = case_content(case_record), do: unfreeze_content(content)

        abusive_reports =
          from(r in Report,
            where: r.case_id == ^case_record.id and r.id in ^abusive_report_ids,
            preload: :reporter
          )
          |> Repo.all()

        for report <- abusive_reports, do: mark_abusive(report, updated, admin)

        # After the abusive marks, never before: `Report.awaiting_outcome/1`
        # reads that column, and a reporter an admin has just called a weapon
        # is not owed a polite decision notice on top of their strike.
        Notifier.reporters_case_closed(updated)

        # An unfounded report must not leave the two accounts separated.
        restore_severed(updated, admin)

        {:ok, updated}
    end
  end

  # Records that one report was a deliberate weapon and, where there is an
  # account behind it, strikes its reporter.
  #
  # An outside notifier (issue #2009) has none, and `issue_strike/4` matches on
  # `%User{}` — so an unguarded call raised here rather than doing nothing. The
  # mark itself is the consequence in that case: `trusted_reporter_emails/1`
  # reads it, and one abusive mark costs that address the instant freeze for a
  # year.
  defp mark_abusive(%Report{} = report, %Case{} = case_record, %User{} = admin) do
    report
    |> Ecto.Changeset.change(abusive?: true)
    |> Repo.update!()

    if report.reporter, do: issue_strike(report.reporter, case_record, "reporter", admin)
    :ok
  end

  @doc """
  Admin ruling for a clear-cut abusive account (spam being the common case):
  remove the owner outright, **skipping the warn-first strike ladder**.

    * `:deactivate` — resolve the case and permanently deactivate the account
      (`deactivated_at`), stamping the internal `moderation_reason` (default
      `"spam"`) so admins can filter and later restore it
      (`Vutuv.Accounts.admin_restore_user/1`). Reported posts/messages stay
      frozen as evidence. The owner is **not** emailed.
    * `:delete` — resolve the case and delete the account and everything it owns
      through `Vutuv.Accounts.admin_delete_user/1` (the operator gets a record;
      the member gets nothing). The case row is erased with the account.

  Returns `{:ok, case}` (deactivate), `{:ok, :deleted}` (delete) or
  `{:error, :not_open}` when the case was already resolved.
  """
  def remove_owner(case_record, admin, action, reason \\ "spam")

  def remove_owner(%Case{} = case_record, %User{admin?: true} = admin, :deactivate, reason) do
    case claim_case_resolution(case_record, "upheld", admin) do
      :already_resolved ->
        {:error, :not_open}

      {:ok, updated} ->
        now = NaiveDateTime.utc_now(:second)
        owner = Repo.get!(User, case_record.owner_id)
        set_user_moderation!(owner.id, deactivated_at: now, moderation_reason: reason)
        log(updated, admin, "owner_removed", %{"action" => "deactivate", "reason" => reason})
        Notifier.reporters_case_closed(updated)
        # A removal that does not come back gets the same actor `Delete` a real
        # account deletion sends (issue #1102), or the member keeps federating
        # from every server that follows them. `410 Gone` stays reserved for the
        # member's own opt-out, so this is a broadcast, not a status code.
        Fediverse.revoke_actor(owner)
        {:ok, updated}
    end
  end

  def remove_owner(%Case{} = case_record, %User{admin?: true} = admin, :delete, _reason) do
    case claim_case_resolution(case_record, "upheld", admin) do
      :already_resolved ->
        {:error, :not_open}

      {:ok, updated} ->
        # The reporters are told **first**, because the deletion below takes
        # this case and its reports with it (owner FK on_delete: :delete_all)
        # and there would be nobody left to look up. Their mail stands; their
        # in-app entry is derived from the report row, so it goes with it —
        # the accepted price of a ruling that erases its own evidence.
        Notifier.reporters_case_closed(updated)

        # No case-side audit line: admin_delete_user erases the account and, with
        # it, this case and its events (owner FK on_delete: :delete_all), so any
        # event would be deleted the same instant. The operator record email from
        # admin_delete_user is the surviving audit for a deletion.
        {:ok, _} = Accounts.admin_delete_user(Repo.get!(User, case_record.owner_id))
        {:ok, :deleted}
    end
  end

  ## Strikes

  @doc "Unexpired strikes against this member."
  def active_strike_count(%User{id: user_id}) do
    now = NaiveDateTime.utc_now(:second)

    Strike.where_user(user_id)
    |> where([s], s.expires_at > ^now)
    |> Repo.aggregate(:count)
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

    log(case_record, admin, "strike_issued", %{"role" => role, "level" => level})
    apply_ladder(user, level, now, case_record, role)
  end

  # What the warning names as the ground it rests on. The case page tells the
  # owner of a copyright case outright that this is the law and not a house
  # rule; the warning that followed cited the community guidelines and linked
  # them, so the two letters about one case disagreed (issue #2067). Asked
  # inside the level-1 clause, because it costs a query on a case struct that
  # carries no reports and only the warning has a use for the answer — the two
  # rungs above it are about a ladder, not about one case.
  #
  # Only the **owner** can be struck on a copyright ground. A reporter's strike
  # is for weaponising the report button, which is a house rule whatever the
  # case underneath it was about.
  defp strike_ground(%Case{} = case_record, "owner"),
    do: if(copyright_case?(case_record), do: :copyright, else: :community)

  defp strike_ground(%Case{}, _role), do: :community

  defp apply_ladder(user, 1, _now, case_record, role) do
    Notifier.strike_warning(user, strike_ground(case_record, role))
  end

  defp apply_ladder(user, 2, now, _case_record, _role) do
    until = NaiveDateTime.add(now, @suspension_days * 86_400)
    set_user_moderation!(user.id, suspended_until: until)
    Notifier.suspension(user, until)
  end

  defp apply_ladder(user, _level, now, _case_record, _role) do
    set_user_moderation!(user.id, deactivated_at: now)
    Notifier.deactivation(user)
    # The third strike is permanent, so it federates like the admin's own
    # removal above (issue #1102). The week's suspension one rung down does not:
    # a temporary hiding must never tell the network an account is gone.
    Fediverse.revoke_actor(user)
  end

  ## Relationship severance

  # Reporting someone is a statement that the contact is unwanted: the two
  # accounts are separated on the spot - connection and follows removed, the
  # 1:1 conversation frozen for both sides - before any second report or
  # admin ruling. What existed is recorded in a `Severance` row so a rejected
  # case can put it back (`restore_severed/2`); an upheld case leaves the
  # separation in place. The reporter is told (flash via `severed_for?/2`,
  # plus the in-app feed `Vutuv.Activity` derives from the severance rows).
  # Reporting an organization page must not cut the reporter's personal ties to the
  # member who happens to have claimed it: severance is a between-people
  # protection, meaningless for a business page.
  # Only ever called for a member's report. An outside notifier has no account,
  # so there is no tie to cut and no `moderation_severances` row to write —
  # that table's `reporter_id` is a NOT NULL foreign key to `users` and stays
  # one, which is why the public path deliberately does not reach here.
  defp sever_relationship(%Case{content_type: "organization"}, %User{}), do: :ok

  defp sever_relationship(%Case{} = case_record, %User{} = reporter) do
    owner_id = case_record.owner_id
    ties = Vutuv.Social.sever_between(reporter.id, owner_id)
    conversation = Vutuv.Chat.freeze_conversation_between(reporter.id, owner_id)

    if ties.follow_a_to_b || ties.follow_b_to_a || conversation do
      # A mutual follow is what made the pair vernetzt, so recording the two
      # follow edges is enough to restore the connection on a rejected case.
      # There is no separate connection state to capture any more.
      severance =
        Repo.insert!(%Severance{
          case_id: case_record.id,
          reporter_id: reporter.id,
          owner_id: owner_id,
          had_follow_reporter_to_owner?: ties.follow_a_to_b,
          had_follow_owner_to_reporter?: ties.follow_b_to_a,
          conversation_id: conversation && conversation.id
        })

      log(case_record, reporter, "relationship_severed", %{
        "follows" => Enum.count([ties.follow_a_to_b, ties.follow_b_to_a], & &1),
        "conversation" => conversation != nil
      })

      Vutuv.Activity.notify_report_protection(
        reporter.id,
        Repo.get(User, owner_id),
        "severed",
        severance.id
      )
    end

    :ok
  end

  # The rejected case's severances are rolled back: connection and follows
  # recreated as they were (unless the two already rebuilt them), the
  # conversation thawed - except when another still-open case between the
  # same two people holds its own severance.
  defp restore_severed(%Case{} = case_record, %User{} = admin) do
    severances =
      Repo.all(
        from(s in Severance, where: s.case_id == ^case_record.id and is_nil(s.restored_at))
      )

    for severance <- severances do
      restored? = restore_or_handover(severance)

      severance
      |> Ecto.Changeset.change(restored_at: NaiveDateTime.utc_now(:second))
      |> Repo.update!()

      # Only announce a restoration that actually happened — when a block or
      # another open report kept the ties severed, nothing was put back, so the
      # reporter must not be told their relationship was restored.
      if restored? do
        log(case_record, admin, "relationship_restored", %{
          "reporter_id" => severance.reporter_id
        })

        Vutuv.Activity.notify_report_protection(
          severance.reporter_id,
          Repo.get(User, severance.owner_id),
          "restored",
          severance.id
        )
      end
    end

    :ok
  end

  # Returns true when the ties were actually put back.
  defp restore_or_handover(%Severance{} = severance) do
    cond do
      # Another open report still holds its own severance: leave everything cut.
      other_active_severance?(severance) ->
        false

      # A block now owns the separation: don't restore follows/connection (the
      # blocked author's posts would flow back into the blocker's feed), and
      # hand the conversation freeze to the block so a later unblock thaws it
      # (otherwise it would stay frozen forever once the report releases it).
      # Looks the frozen conversation up fresh, so it works even when a second
      # case's severance — whose own conversation_id is nil — is the one being
      # rejected.
      Vutuv.Social.blocked_between?(severance.reporter_id, severance.owner_id) ->
        Vutuv.Social.adopt_conversation_freeze(severance.reporter_id, severance.owner_id)
        false

      true ->
        restore_ties(severance)
        true
    end
  end

  defp restore_ties(%Severance{} = severance) do
    Vutuv.Social.restore_between(severance.reporter_id, severance.owner_id,
      follow_a_to_b: severance.had_follow_reporter_to_owner?,
      follow_b_to_a: severance.had_follow_owner_to_reporter?
    )

    if severance.conversation_id do
      conversation = Repo.get(Vutuv.Chat.Conversation, severance.conversation_id)

      if conversation && conversation.frozen_at,
        do: Vutuv.Chat.unfreeze_conversation(conversation)
    end

    :ok
  end

  defp other_active_severance?(%Severance{} = severance) do
    active_severances_between(severance.reporter_id, severance.owner_id)
    |> where([s], s.id != ^severance.id)
    |> Repo.exists?()
  end

  @doc """
  Whether filing a report against `content` would sever a standing
  relationship between `reporter` and the content's owner. Drives the report
  form's up-front warning: the reporter must understand the consequence (and
  the de-facto loss of anonymity towards a member they are tied to) BEFORE
  sending, not after.
  """
  def would_sever_relationship?(%User{}, %Organization{}), do: false

  def would_sever_relationship?(%User{} = reporter, content) do
    owner = owner_id(content)

    owner != nil and owner != reporter.id and
      (Vutuv.Social.tie_between?(reporter.id, owner) or
         Vutuv.Chat.active_conversation_between?(reporter.id, owner))
  end

  @doc "The member owning the reportable content (nil when already deleted)."
  def content_owner(content) do
    case owner_id(content) do
      nil -> nil
      id -> Repo.get(User, id)
    end
  end

  @doc """
  Whether an unrestored severance stands between the two (either direction).
  `Vutuv.Social.unblock_user/2` consults it: a conversation a report froze
  must stay frozen when a block on the same pair is lifted - the report's
  ruling owns that freeze.
  """
  def active_severance_between?(a_id, b_id) do
    active_severances_between(a_id, b_id) |> Repo.exists?()
  end

  defp active_severances_between(a_id, b_id) do
    from(s in Severance,
      where: is_nil(s.restored_at),
      where:
        (s.reporter_id == ^a_id and s.owner_id == ^b_id) or
          (s.reporter_id == ^b_id and s.owner_id == ^a_id)
    )
  end

  @doc """
  Whether this member's report cut a standing relationship - drives the
  reporter-facing notice after filing the report.
  """
  def severed_for?(case_id, reporter_id) do
    Repo.exists?(
      from(s in Severance, where: s.case_id == ^case_id and s.reporter_id == ^reporter_id)
    )
  end

  @doc """
  Every severance this member's reports caused. `Vutuv.Activity` derives the
  reporter's protection notifications (severed + restored) from this, so the
  feed cannot drift from what actually happened.
  """
  def reporter_severances_query(user_id) do
    from(s in Severance, where: s.reporter_id == ^user_id)
  end

  @doc """
  Every decision notice this member has been sent as a **reporter** (issue
  #2011). `Vutuv.Activity` derives the `report_outcome` entries from it.

  Keyed on `outcome_notified_at` rather than on the case's status, for the
  reason `reporter_severances_query/1` lives here too: the in-app line must say
  exactly what the mail said, so both read the one row that records the notice
  went out. A closed case nobody was told about (an unconfirmed notice, an
  abusive report) therefore has no line either.

  It carries **no join to the case**: two of its three readers are on the
  notification-badge path, which every page render runs, and Postgres never
  eliminates an inner join for a column nobody selected. The one reader that
  needs the ending joins for itself.
  """
  def reporter_outcome_query(user_id) do
    from(r in Report, where: r.reporter_id == ^user_id and not is_nil(r.outcome_notified_at))
  end

  @doc "The case's severances (what reporting cut), for the admin case page."
  def case_severances(%Case{id: id}) do
    Repo.all(from(s in Severance, where: s.case_id == ^id, order_by: [asc: s.inserted_at]))
  end

  ## Audit log

  @doc "The case's full history, oldest first, with actors preloaded."
  def case_events(%Case{id: id}), do: case_events(id)

  def case_events(case_id) do
    from(e in Event,
      where: e.case_id == ^case_id,
      order_by: [asc: e.inserted_at, asc: e.id],
      preload: :actor
    )
    |> Repo.all()
  end

  # One audit-log row. `actor` is the member who caused the step (nil for
  # system actions); `detail` carries small action-specific facts.
  defp log(%Case{id: case_id}, actor, action, detail \\ %{}) do
    Repo.insert!(%Event{
      case_id: case_id,
      actor_id: actor && actor.id,
      action: action,
      detail: detail
    })

    :ok
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
    # A nil in this list is not merely useless (`r.reporter_id in (NULL, …)` is
    # never true for a NULL row): the caller then looks the answer up by nil and
    # gets nothing back. Dropped here so no caller has to remember.
    stats_map(:reporter_id, Enum.filter(reporter_ids, &is_binary/1))
  end

  @doc """
  The track record behind each of `reports`, keyed by **report id**:
  `%{report_id => %{total:, rejected:, abusive:}}`.

  The admin case page's shape, and the reason it is keyed by the report rather
  than by the reporter: a case can now carry both a member's report and an
  outside notice, and those are counted in two different tables' worth of rows
  (by user id, by confirmed address). Keying by the reporter meant looking one
  up by `nil`, which is a `KeyError` and a 500 on the case page.
  """
  def report_stats(reports) when is_list(reports) do
    by_id = reports |> member_reporter_ids() |> reporter_stats_map()
    by_email = reports |> outside_reporter_emails() |> outside_stats_map()
    empty = %{total: 0, rejected: 0, abusive: 0}

    Map.new(reports, fn
      %Report{id: id, reporter_id: user_id} when is_binary(user_id) ->
        {id, Map.get(by_id, user_id, empty)}

      %Report{id: id, reporter_email: email} ->
        {id, Map.get(by_email, email, empty)}
    end)
  end

  defp outside_stats_map(emails), do: stats_map(:reporter_email, emails)

  # The all-time counts an admin sees beside a report, keyed by whichever column
  # names its reporter — the user id for a member, the confirmed address for an
  # outside notifier (issue #2009).
  defp stats_map(_column, []), do: %{}

  defp stats_map(column, keys) do
    from(r in Report,
      join: c in assoc(r, :case),
      where: field(r, ^column) in ^keys,
      group_by: field(r, ^column),
      select:
        {field(r, ^column),
         %{
           total: count(r.id),
           rejected: fragment("COUNT(*) FILTER (WHERE ? = 'rejected')", c.status),
           abusive: fragment("COUNT(*) FILTER (WHERE ?)", r.abusive?)
         }}
    )
    |> Report.effective()
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The misuse dashboard: everyone who has filed a report, with their track
  record and current trust standing, worst offenders first. Each row carries
  either a `:reporter` (a member) or an `:email` (an outside notifier, issue
  #2009), never both.

  Two grouped queries rather than one, because the two kinds group on different
  columns. Widening the old single query was the alternative and the wrong one:
  it inner-joins `users` on `reporter_id`, so **every** outside notice fell out
  of this page silently — the one screen whose job is to show who abuses the
  report button would not have seen the abuse a public form makes possible.
  """
  def list_reporter_stats do
    (member_reporter_stats() ++ outside_reporter_stats())
    |> Enum.map(fn row ->
      # Both kinds of key on every row, so a template never has to know which
      # query a row came from.
      %{reporter: nil, email: nil}
      |> Map.merge(row)
      |> Map.put(:trusted, trusted?(row.recent_abusive, row.recent_rejected))
      |> Map.drop([:recent_rejected, :recent_abusive])
    end)
    |> Enum.sort_by(&{-&1.abusive, -&1.rejected, -&1.total})
  end

  defp member_reporter_stats do
    from(r in Report,
      join: c in assoc(r, :case),
      join: u in User,
      on: u.id == r.reporter_id,
      group_by: u.id,
      select: %{reporter: u}
    )
    |> with_track_record()
    |> Repo.all()
  end

  # Confirmed notices only: an unconfirmed one is a stranger's unverified claim
  # and has neither earned trust nor lost any, exactly as in
  # `trusted_reporters/2`.
  defp outside_reporter_stats do
    from(r in Report,
      join: c in assoc(r, :case),
      where: not is_nil(r.reporter_email) and not is_nil(r.confirmed_at),
      group_by: r.reporter_email,
      select: %{email: r.reporter_email}
    )
    |> with_track_record()
    |> Repo.all()
  end

  # The five figures a track record is, merged onto whichever key the caller
  # grouped by. Written once because the two windowed `COUNT(*) FILTER` blocks
  # are the part that would drift.
  defp with_track_record(query) do
    window_start = trust_window_start()

    from([r, c] in query,
      select_merge: %{
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
  frozen pending review, currently suspended, deactivated for good, or frozen
  because it is unreachable (every email bounced; see `Vutuv.Deliverability`).
  The unreachable case is a deliverability fact, not a moderation ruling, but it
  hides the profile the same way - a zombie account nobody can reach should not
  sit in the public network.
  """
  def account_hidden?(%User{} = user) do
    user.frozen_at != nil or user.deactivated_at != nil or user.unreachable_at != nil or
      login_block(user) != nil
  end

  @doc """
  The one profile-visibility rule: never-activated accounts are invisible
  to everyone; moderation-hidden accounts stay visible to themselves and
  admins. Both the HTML gate (`VutuvWeb.Plug.EnsureActivated`) and the API
  (`VutuvWeb.ApiV2.fetch_visible_user/2`) decide through this predicate —
  pass `viewer: nil` for renderings that must stay anonymous (the
  agent-format siblings).
  """
  def profile_visible_to?(%User{} = user, viewer) do
    email_confirmed?(user) and (not account_hidden?(user) or bypass?(user, viewer))
  end

  @doc """
  The HTTP status a withheld profile should return to a viewer who cannot see
  it (issue #812). Call it only once `profile_visible_to?/2` has already said
  no; it decides *why* the profile is withheld:

    * `404` — a never-activated registration (the anti-spam gate). These must
      stay indistinguishable from a non-existent account: you must not be able
      to probe whether an email is registered, so this is not negotiable.
    * `410` Gone — a permanently deactivated account (`deactivated_at`). It
      existed and is gone for good.
    * `403` Forbidden — a reversible hold: frozen pending review, currently
      suspended, or frozen for unreachability. The account exists and is
      withheld, which is what 403 says (and what the old blanket 404 lied
      about).

  A confirmed but deactivated account still reports 410 even though its owner
  never confirmed a second address, etc.; the `email_confirmed?` gate wins
  first so an unconfirmed row can never leak its existence through a 403/410.
  """
  def withheld_status(%User{} = user) do
    cond do
      not email_confirmed?(user) -> 404
      user.deactivated_at != nil -> 410
      true -> 403
    end
  end

  # nil counts as activated: rows from before the activation gate existed.
  defp email_confirmed?(%User{email_confirmed?: false}), do: false
  defp email_confirmed?(%User{}), do: true

  defp bypass?(%User{id: id}, %User{id: id}), do: true
  defp bypass?(_user, %User{admin?: true}), do: true
  defp bypass?(_user, _viewer), do: false

  ## Admin account freeze (issue #812)

  @doc """
  Admin-initiated freeze of an account (no report, no case): hides the profile
  and everything it owns from everyone but the owner and admins, exactly like a
  report-driven freeze (`account_hidden?/1` flips, `profile_visible_to?/2`
  hides it, the owner sees their `frozen_banner`). It sets `frozen_at` only, so
  it does **not** block login (`login_block/1` fires on suspension/deactivation,
  not a freeze); a frozen member can still sign in and see their own banner.

  Records a caseless `AdminAction` audit row (who froze whom, when, why). The
  public, audited entry point the admin account tool uses instead of the
  private `set_user_moderation!/2`.

  Returns `{:ok, :frozen}`, or `{:ok, :noop}` if the account was already frozen.
  """
  def admin_freeze_user(user, admin, reason \\ nil)

  def admin_freeze_user(%User{frozen_at: %NaiveDateTime{}}, %User{admin?: true}, _reason),
    do: {:ok, :noop}

  def admin_freeze_user(%User{} = user, %User{admin?: true} = admin, reason) do
    set_user_moderation!(user.id, frozen_at: NaiveDateTime.utc_now(:second))
    log_admin_action(user, admin, "account_frozen", reason)
    {:ok, :frozen}
  end

  @doc """
  Admin-initiated thaw: lifts a `frozen_at` hold, whatever set it (an admin
  freeze or a report). Clearing a report-driven freeze un-hides the profile
  while the case stays open in the queue — a deliberate admin override ("I have
  looked, un-hide it"); the case ruling later clears an already-nil `frozen_at`
  as a no-op. Records a caseless `AdminAction` audit row.

  Returns `{:ok, :unfrozen}`, or `{:ok, :noop}` if it was not frozen.
  """
  def admin_unfreeze_user(user, admin, reason \\ nil)

  def admin_unfreeze_user(%User{frozen_at: nil}, %User{admin?: true}, _reason),
    do: {:ok, :noop}

  def admin_unfreeze_user(%User{} = user, %User{admin?: true} = admin, reason) do
    set_user_moderation!(user.id, frozen_at: nil)
    log_admin_action(user, admin, "account_unfrozen", reason)
    {:ok, :unfrozen}
  end

  defp log_admin_action(%User{} = user, %User{} = admin, action, reason) do
    Repo.insert!(%AdminAction{
      user_id: user.id,
      actor_id: admin.id,
      action: action,
      reason: SearchText.normalize_search(reason)
    })

    :ok
  end

  @doc "How many accounts are currently in the moderation freezer (`frozen_at` set)."
  def frozen_accounts_count do
    Repo.aggregate(from(u in User, where: not is_nil(u.frozen_at)), :count)
  end

  @doc """
  One page of currently-frozen accounts, newest freeze first, paginated like
  the admin member browser (`Vutuv.Pages.paginate/4`). `opts` may carry
  `:total` (skip the recount) and `:per_page`.
  """
  def list_frozen_accounts(params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 250)
    total = Keyword.get(opts, :total) || frozen_accounts_count()

    from(u in User, where: not is_nil(u.frozen_at), order_by: [desc: u.frozen_at, desc: u.id])
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  @doc """
  Of the given account ids, the set currently frozen by an open report (a user
  `Case` in an open status). Drives the frozen list's "Source" column: an id in
  the set was frozen by a report, everything else by an admin. One query, no
  per-row lookups.
  """
  def report_frozen_ids(user_ids) when is_list(user_ids) do
    from(c in Case,
      where: c.content_type == "user" and c.owner_id in ^user_ids and c.status in ^@open_statuses,
      select: c.owner_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  ## Content plumbing

  @doc """
  The wire string for a reportable row — the inverse of `fetch_content/2`.
  Public because the notice form resolves a pasted URL to a row and then needs
  to know which categories that row offers.
  """
  def content_type(%Post{}), do: "post"
  def content_type(%Message{}), do: "message"
  def content_type(%User{}), do: "user"
  def content_type(%Organization{}), do: "organization"
  def content_type(%JobPosting{}), do: "job_posting"
  def content_type(%Image{}), do: "image"

  defp content_id(%{id: id}), do: id

  # A post published in an organization's name (issue #1334) answers to the same
  # member the page itself does — whoever claimed it — rather than to whoever
  # pressed publish. The page's content is the page's, so its accountability
  # must not move from person to person with each post, and a publisher who has
  # since lost the role would otherwise still carry strikes for it. When that
  # member is gone (`nilify_all`) there is nobody to strike and the report is
  # refused, exactly as it already is for the organization page itself.
  defp owner_id(%Post{user_id: nil, organization_id: id}) when is_binary(id) do
    Repo.one(from(o in Organization, where: o.id == ^id, select: o.created_by_user_id))
  end

  defp owner_id(%Post{user_id: user_id}), do: user_id
  defp owner_id(%Message{sender_id: sender_id}), do: sender_id
  defp owner_id(%User{id: id}), do: id
  # The member who claimed the page carries the strike ladder; an organization whose
  # creator has since deleted their account (nilify_all) has no owner to strike,
  # so report_content/3 refuses it (owner_id == nil), leaving the report path
  # only for admin freeze.
  defp owner_id(%Organization{created_by_user_id: user_id}), do: user_id
  defp owner_id(%JobPosting{user_id: user_id}), do: user_id
  # A picture with no member owner is one of the kinds #2015 brings into the
  # table (a post photo, an organization logo). There is nobody to strike and
  # no member row to clear, so `can_report?/2` refuses it rather than guessing.
  defp owner_id(%Image{user_id: user_id}), do: user_id

  defp snapshot(%Post{body: body}), do: body
  defp snapshot(%Message{body: body}), do: body

  defp snapshot(%JobPosting{} = posting) do
    [posting.title, posting.description]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp snapshot(%User{} = user) do
    [Identity.display_name(user), user.headline]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # A picture has no text, so the snapshot names which picture it was — the
  # case pages show the picture itself through the authorized preview.
  defp snapshot(%Image{} = image), do: image.file || image.kind

  defp snapshot(%Organization{} = organization) do
    [organization.name, organization.city]
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
  defp reportable_by?(_reporter, %Organization{}), do: true
  # A profile picture is as public as the profile it sits on, and a rights
  # holder reporting one is exactly the stranger this type exists for.
  #
  # Only a picture whose takedown is actually wired, though. #2015 moves the
  # gallery kinds into `images` one release at a time, and the expand half
  # gives them a row before `Vutuv.Images.freeze/1` has a clause for them — a
  # case opened on such a row would raise the moment an admin upheld it. Those
  # keep the affordance they had before the row existed: reporting the post,
  # the posting or the page the picture sits on.
  defp reportable_by?(_reporter, %Image{} = image), do: Images.takedown_ready?(image)

  defp reportable_by?(reporter, %JobPosting{} = posting),
    do: Vutuv.Jobs.visible_to?(posting, reporter)

  # A picture's freeze is a file move, not a column write: every size and the
  # private original leave the trees a reader can reach for the hold nginx has
  # no location for, and the profile falls back to the silhouette meanwhile
  # (`Vutuv.Images.freeze/1`, issue #2012).
  defp freeze_content(%Image{} = image), do: Images.freeze(image)

  defp freeze_content(content) do
    set_frozen_at(content, NaiveDateTime.utc_now(:second))

    # Open chat threads drop the message live; posts need no push (the read
    # paths filter on the next render).
    if match?(%Message{}, content), do: Vutuv.Chat.broadcast_message_frozen(content)
    # A frozen post is invisible to everyone but its owner here, so the copies on
    # other servers have to be asked to go too, or the freeze is a local fiction
    # (issue #1102). Best effort and reversible: lifting the freeze publishes it
    # again. A frozen *profile* deliberately sends nothing — see the freeze note
    # in `Vutuv.Fediverse.revoke_actor/1`: a temporary hiding must never tell the
    # network an account is gone, and one report must not fan a Delete out over
    # every post the member ever published.
    if match?(%Post{}, content), do: Fediverse.revoke_post(content)
    :ok
  end

  defp unfreeze_content(%Image{} = image), do: Images.unfreeze(image)

  defp unfreeze_content(content) do
    set_frozen_at(content, nil)
    # The other half of revoking on a freeze: a rejected report (or the owner's
    # own edit) has to put the post back on the other servers, not only here.
    if match?(%Post{}, content), do: Fediverse.republish_post(content)
    :ok
  end

  defp set_frozen_at(%Post{id: id}, value) do
    Repo.update_all(from(p in Post, where: p.id == ^id), set: [frozen_at: value])
  end

  defp set_frozen_at(%Message{id: id}, value) do
    Repo.update_all(from(m in Message, where: m.id == ^id), set: [frozen_at: value])
  end

  defp set_frozen_at(%User{id: id}, value) do
    set_user_moderation!(id, frozen_at: value)
  end

  defp set_frozen_at(%Organization{id: id}, value) do
    Repo.update_all(from(c in Organization, where: c.id == ^id), set: [frozen_at: value])
  end

  defp set_frozen_at(%JobPosting{id: id}, value) do
    Repo.update_all(from(p in JobPosting, where: p.id == ^id), set: [frozen_at: value])
    # A freeze pulls the posting off the public board (and an unfreeze puts it
    # back), so ping any open board to re-query (#933).
    Vutuv.Jobs.notify_board_changed()
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
  defp content_schema("organization"), do: Organization
  defp content_schema("job_posting"), do: JobPosting
  defp content_schema("image"), do: Image
  defp content_schema(_), do: nil
end
