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

  alias Vutuv.{Accounts, Activity, Repo}
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation.Case
  alias Vutuv.Notifications.Emailer

  @doc "The owner's content was frozen; they can delete, edit or dispute."
  def owner_content_frozen(%Case{} = case_record) do
    push_owner(case_record, "One of your contributions was reported and is hidden for now.")
    mail_owner(case_record, &Emailer.moderation_frozen_email/3)
  end

  @doc "The owner's content was frozen and is with the admins (no self-service)."
  def owner_under_review(%Case{} = case_record) do
    push_owner(case_record, "One of your contributions is hidden while our admins review it.")
    mail_owner(case_record, &Emailer.moderation_review_email/3)
  end

  @doc "Tell every reporter of the case that the owner revised the content."
  def reporters_content_revised(%Case{} = case_record) do
    case_record = Repo.preload(case_record, reports: :reporter)

    for report <- case_record.reports do
      deliver_to(report.reporter, &Emailer.moderation_revised_email/2)
    end

    :ok
  end

  @doc "Strike 1: a formal warning."
  def strike_warning(%User{} = user) do
    deliver_to(user, &Emailer.moderation_warning_email/2)
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

  defp push_owner(%Case{} = case_record, text) do
    Activity.notify(case_record.owner_id, %{
      kind: "moderation",
      text: text,
      case_id: case_record.id,
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
