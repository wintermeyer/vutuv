defmodule Vutuv.Moderation.Notifier do
  @moduledoc """
  All moderation side effects in one place: the emails (built and sent
  through the `Vutuv.Notifications.Emailer` chokepoint) and the live in-app
  pushes (`Vutuv.Activity`). Every function is fire-and-forget: a member
  without an email address simply gets no mail.

  Emails are delivered **off the calling process** (one supervised task per
  recipient): these run inside member-facing requests — reporting a profile
  mails every admin — and the production mailer is synchronous SMTP, so one
  slow MX must not stall the HTTP request. A failed delivery was already
  ignored when it was inline; moving it to a task loses nothing. Tests run
  deliveries inline (`config :vutuv, :async_email, false`) because the
  Swoosh test adapter hands the email to the calling process.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.{Accounts, Activity, Moderation, Repo}
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation.{Case, Report}
  alias Vutuv.Notifications.Emailer

  @doc """
  The owner's content was frozen; they can delete, edit or dispute.

  Both owner notices carry the statement of reasons (issue #2010), so the
  reports come along — `:reports` alone, never `reports: :reporter`: a report
  is anonymous, and a surface cannot leak what it was never handed. And only
  the **effective** ones (`Moderation.effective_reports/0`), so a notice whose
  address nobody has confirmed is not even loaded into a mail that quotes a
  stranger's words to the member they accuse.
  """
  def owner_content_frozen(%Case{} = case_record) do
    case_record = Repo.preload(case_record, reports: Moderation.effective_reports())
    push_owner(case_record)
    mail_owner(case_record, &Emailer.moderation_frozen_email/3)
  end

  @doc "The owner's content was frozen and is with the admins (no self-service)."
  def owner_under_review(%Case{} = case_record) do
    case_record = Repo.preload(case_record, reports: Moderation.effective_reports())
    push_owner(case_record)
    mail_owner(case_record, &Emailer.moderation_review_email/3)
  end

  @doc """
  Tell every reporter of a closed case how it ended — each of them once
  (issue #2011).

  All five ways a case closes call this (`uphold_case/2`, `reject_case/3`, the
  owner's delete, the owner's edit, the erasing `remove_owner/4`), because a
  reporter who hears nothing goes back to the URL for days and files the notice
  again. What they are told is read off the case's own status
  (`Moderation.reporter_outcome/1`), never passed in, so a caller cannot state
  an ending the row does not have; a case that is not closed is a no-op.

  **Exactly once is a claim, not a convention.** The one `UPDATE` below both
  picks the reports that still owe their reporter a notice and stamps them, in
  a single statement, so a second close, a retry, or two admins ruling at the
  same instant find no rows left and mail nobody twice; only the rows that
  statement returns are delivered to. And every value the delivery needs is
  read *here*, before any task is spawned — a case can be erased with its
  account (`remove_owner/4` on `:delete`) while the mail is still in flight, and
  a task that went looking for the row again would find nothing and quietly send
  nothing.

  Who is left out — an unconfirmed outside notice, an abusive report — is
  `Report.awaiting_outcome/1`'s decision, spelled once there.

  `:fate` overrides the measurement for the **one** caller that cannot be
  measured: `remove_owner/4` on `:delete` has to tell the reporters before it
  erases the case, so reading the content then answers "still here" about
  something that is gone a line later. Every other path settles the content
  first and lets `Moderation.reported_content_fate/1` look.

  The subject and the closing paragraph come from those two different sources,
  so before anything is sent `Moderation.consistent_outcome?/2` is asked
  whether they can stand in one letter (issue #2071). If they cannot, nothing
  goes out, the claim is given back so no row falsely reads as answered, and
  the log says so — see `refuse_contradicting_notice/4`.
  """
  def reporters_case_closed(%Case{} = case_record, opts \\ []) do
    deliver_outcomes(case_record, Case.reporter_outcome(case_record.status), opts[:fate])
  end

  # Still open: nothing to tell anybody, and nothing claimed.
  defp deliver_outcomes(_case_record, nil, _fate), do: :ok

  defp deliver_outcomes(%Case{} = case_record, outcome, stated_fate) do
    now = NaiveDateTime.utc_now(:second)

    {_count, reports} =
      case_record.id
      |> Report.awaiting_outcome()
      |> select(
        [r],
        struct(r, [:id, :reporter_id, :reporter_email, :reporter_name, :reporter_locale])
      )
      |> Repo.update_all(set: [outcome_notified_at: now, updated_at: now])

    if reports != [], do: deliver_or_refuse(case_record, reports, outcome, stated_fate)

    :ok
  end

  # What became of the content, read **here**: the ruling has already settled it
  # (purged a picture, unfrozen a profile, left a post frozen) and the delivery
  # tasks run later, on a row `remove_owner/4` may by then have erased. Once per
  # case rather than per reporter, and only once the `UPDATE` above says
  # somebody is actually owed a notice — a second close or a retry claims no
  # rows and must not pay for a lookup nothing reads.
  defp deliver_or_refuse(%Case{} = case_record, reports, outcome, stated_fate) do
    fate = stated_fate || Moderation.reported_content_fate(case_record)

    if Moderation.consistent_outcome?(outcome, fate) do
      reporters = reporters_by_id(reports)

      for report <- reports, do: deliver_outcome(report, reporters, outcome, fate)
    else
      refuse_contradicting_notice(case_record, reports, outcome, fate)
    end
  end

  # The letter's two halves meet here, so this is where the rule against them
  # contradicting each other is asked (issue #2071). It had existed since #2067
  # and only tests ever called it — with the fate they expected rather than the
  # one the system produced, so it compared a sentence with itself.
  #
  # What it does when it fires is two decisions. **No mail**: a subject saying
  # the content was deleted over a paragraph saying it is merely hidden is
  # worse for the person reading it than silence, and this is a legal notice.
  # **The claim goes back**: leaving `outcome_notified_at` stamped would record
  # in the database that these reporters were told, which is false, and
  # `Report.awaiting_outcome/1` is what any later answer has to read. Be clear
  # about what that does and does not buy — nothing re-drives it. That query
  # has one reader (`deliver_outcomes/3`), no sweeper wakes it, and a closed
  # case cannot re-enter `settle_case/3`, so in practice a fired guard is
  # permanent silence for that reporter. The row stays honest and the log is
  # what an operator acts on; the deeper fix is to refuse the contradicting
  # *ending* rather than the letter, in the close path itself.
  defp refuse_contradicting_notice(%Case{} = case_record, reports, outcome, fate) do
    ids = Enum.map(reports, & &1.id)

    Repo.update_all(from(r in Report, where: r.id in ^ids), set: [outcome_notified_at: nil])

    Logger.error(
      "moderation: no decision notice sent for case #{case_record.id} " <>
        "(status #{case_record.status}) - the ending #{inspect(outcome)} and the content's " <>
        "measured fate #{inspect(fate)} contradict each other " <>
        "(Vutuv.Moderation.consistent_outcome?/2). #{length(ids)} reporter(s) still owed one."
    )
  end

  # One query for every member reporter on the case, not one per report: a
  # popular post collects dozens, and this runs inside the ruling request.
  defp reporters_by_id(reports) do
    ids = for %Report{reporter_id: id} <- reports, is_binary(id), do: id

    if ids == [] do
      %{}
    else
      from(u in User, where: u.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  # A member reporter: the in-app entry (derived from the row this stamped, so
  # the push and the persisted line are the same event) plus the mail.
  defp deliver_outcome(%Report{reporter_id: reporter_id} = report, reporters, outcome, fate)
       when is_binary(reporter_id) do
    Activity.notify(reporter_id, %{
      kind: "report_outcome",
      outcome: outcome,
      source_id: report.id,
      at: DateTime.utc_now()
    })

    case Map.get(reporters, reporter_id) do
      nil ->
        :ok

      reporter ->
        deliver_to(reporter, fn user, email ->
          Emailer.moderation_outcome_email(user, email, outcome, fate)
        end)
    end
  end

  # An outside notifier (issue #2009): no account, so no in-app anything, and
  # the name and language ride the report row.
  defp deliver_outcome(%Report{reporter_email: address} = report, _reporters, outcome, fate)
       when is_binary(address) do
    notice = %{
      name: report.reporter_name,
      email: address,
      locale: report.reporter_locale,
      outcome: outcome,
      fate: fate
    }

    Emailer.deliver_async(fn ->
      notice |> Emailer.public_notice_outcome_email() |> Emailer.deliver()
    end)
  end

  defp deliver_outcome(_report, _reporters, _outcome, _fate), do: :ok

  @doc """
  The AI image scan rejected and deleted one of the member's images
  (`Vutuv.Moderation.ImageScans`): a live in-app push plus the email with the
  short reasoning (only family-friendly, work-safe images). The notification
  feed itself derives the entry from the rejected scan row, so it survives
  the live push.
  """
  def image_rejected(%Vutuv.Moderation.ImageScan{} = scan) do
    case Repo.get(User, scan.owner_user_id) do
      nil ->
        :ok

      owner ->
        Activity.notify(owner.id, %{
          kind: "image_rejected",
          image_kind: scan.kind,
          source_id: scan.id,
          at: DateTime.utc_now()
        })

        deliver_to(owner, fn user, email -> Emailer.image_rejected_email(user, email, scan) end)
    end
  end

  @doc """
  Strike 1: a formal warning, naming the ground the ruling rested on
  (`:copyright` or `:community`) — the same ground the owner's case page named
  when the content was first hidden (issue #2067).
  """
  def strike_warning(%User{} = user, ground) do
    deliver_to(user, fn user, email -> Emailer.moderation_warning_email(user, email, ground) end)
  end

  @doc "Strike 2: a temporary suspension."
  def suspension(%User{} = user, until) do
    deliver_to(user, fn user, email ->
      Emailer.moderation_suspension_email(user, email, until)
    end)
  end

  @doc "Strike 3: deactivated for good."
  def deactivation(%User{} = user) do
    deliver_to(user, &Emailer.moderation_deactivation_email/2)
  end

  @doc "A profile was reported: mail every admin right away (urgent)."
  def admins_urgent(%Case{} = case_record) do
    # The mail names the owner, the category and the reporter's note, so the
    # builder needs the case fully hydrated.
    case_record = Repo.preload(case_record, [:owner, reports: :reporter])

    for admin <- list_admins() do
      deliver_to(admin, fn user, email ->
        Emailer.moderation_admin_urgent_email(user, email, case_record)
      end)
    end

    :ok
  end

  @doc "The daily digest: how many cases wait in the queue (sent when > 0)."
  def admins_digest(open_count) when open_count > 0 do
    for admin <- list_admins() do
      deliver_to(admin, fn user, email ->
        Emailer.moderation_admin_digest_email(user, email, open_count)
      end)
    end

    :ok
  end

  def admins_digest(_), do: :ok

  # The live push carries the same category the persisted row will
  # (`Vutuv.Activity.moderation_items/3` reads it back from the reports), so
  # the popup and the row under the bell say the same thing. No `:text` — the
  # moderation branch of `VutuvWeb.NotificationLine.notification_text/1` writes
  # the sentence from the category and the status, in the reader's language.
  defp push_owner(%Case{} = case_record) do
    Activity.notify(case_record.owner_id, %{
      kind: "moderation",
      category: Moderation.owner_notice(case_record).category,
      case_id: case_record.id,
      source_id: case_record.id,
      at: DateTime.utc_now()
    })
  end

  defp mail_owner(%Case{} = case_record, builder) do
    case Repo.get(User, case_record.owner_id) do
      nil -> :ok
      owner -> deliver_to(owner, fn user, email -> builder.(user, email, case_record) end)
    end
  end

  # The single send chokepoint: address lookup + SMTP delivery leave the
  # caller's process off the request path (see the moduledoc), via the shared
  # async-email gate in the Emailer.
  defp deliver_to(%User{} = user, build) do
    Emailer.deliver_async(fn ->
      case Accounts.first_email_value(user) do
        nil -> :ok
        address -> user |> build.(address) |> Emailer.deliver()
      end
    end)
  end

  defp list_admins do
    Repo.all(from(u in User, where: u.admin? == true and is_nil(u.deactivated_at)))
  end
end
