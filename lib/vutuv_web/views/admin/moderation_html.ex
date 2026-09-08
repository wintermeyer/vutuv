defmodule VutuvWeb.Admin.ModerationHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Moderation.Case

  embed_templates("../../templates/admin/moderation/*")

  def status_badge(%Case{status: "escalated"}), do: gettext("Escalated")
  def status_badge(%Case{status: "flagged"}), do: gettext("Flagged")
  def status_badge(%Case{status: "pending_owner"}), do: gettext("Waiting for the owner")
  def status_badge(%Case{status: "upheld"}), do: gettext("Upheld")
  def status_badge(%Case{status: "rejected"}), do: gettext("Rejected")
  def status_badge(%Case{status: "resolved_edited"}), do: gettext("Settled by an edit")
  def status_badge(%Case{status: "resolved_deleted"}), do: gettext("Settled by deletion")
  def status_badge(%Case{status: status}), do: status

  def status_tone(%Case{status: "escalated"}), do: "bg-accent/10 text-accent"

  def status_tone(%Case{status: "flagged"}),
    do: "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-200"

  def status_tone(%Case{}),
    do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"

  # Not an admin vocabulary: the same words reach a rights holder who has no
  # account here, in the receipt for their notice, so they live beside
  # `category_label/1` in `VutuvWeb.ReportHTML`.
  defdelegate content_type_label(content_type), to: VutuvWeb.ReportHTML

  @doc """
  Who filed one report: a member as their @handle, somebody with no account
  here as the name and the address they gave (issue #2009), with a badge while
  that address is still unconfirmed.

  One component because two admin surfaces ask it, and it branches on
  `reporter_id`, the **column** — not on the preloaded `:reporter`, which is a
  truthy `%Ecto.Association.NotLoaded{}` for any caller who did not remember
  the preload.
  """
  attr(:report, :map, required: true)

  def reporter_identity(assigns) do
    ~H"""
    <span :if={@report.reporter_id} class="ml-1">
      <a
        href={~p"/#{@report.reporter}"}
        class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        @{@report.reporter.username}
      </a>
    </span>
    <span :if={is_nil(@report.reporter_id)} class="ml-1 font-semibold text-slate-900 dark:text-white">
      {@report.reporter_name}
      <a
        href={Vutuv.Mailto.to(@report.reporter_email)}
        class="font-normal text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        &lt;{@report.reporter_email}&gt;
      </a>
      <span
        :if={is_nil(@report.confirmed_at)}
        class="inline-flex items-center rounded-lg bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-900"
      >
        {gettext("address not confirmed")}
      </span>
    </span>
    """
  end

  # The audit-log line for one moderation event (see Vutuv.Moderation.Event).
  def event_label("report_filed"), do: gettext("Report filed")
  def event_label("content_frozen"), do: gettext("Content frozen")
  def event_label("relationship_severed"), do: gettext("Reporter and owner separated")
  def event_label("relationship_restored"), do: gettext("Separation lifted")
  def event_label("owner_disputed"), do: gettext("Owner disputed the report")
  def event_label("content_edited"), do: gettext("Owner edited the content")
  def event_label("content_deleted"), do: gettext("Content deleted")
  def event_label("content_replaced"), do: gettext("Owner replaced the content")
  def event_label("escalated_deadline"), do: gettext("Escalated - the 72h deadline passed")
  def event_label("upheld"), do: gettext("Report upheld")
  def event_label("rejected"), do: gettext("Report rejected")
  def event_label("owner_removed"), do: gettext("Account removed")
  def event_label("strike_issued"), do: gettext("Strike issued")
  def event_label("evidence_captured"), do: gettext("Evidence screenshot captured")
  def event_label("notice_filed"), do: gettext("Report filed from outside")
  def event_label("notice_confirmed"), do: gettext("Outside reporter confirmed their address")

  def event_label("notice_expired"),
    do: gettext("Report dropped: the address was never confirmed")

  def event_label(other), do: other

  # The small action-specific facts an event carries (JSONB, string keys).
  def event_detail(action, %{"category" => category})
      when is_binary(category) and action in ["report_filed", "notice_filed", "notice_confirmed"],
      do: category_label(category)

  def event_detail("strike_issued", %{"level" => level, "role" => role}) do
    role_label =
      case role do
        "owner" -> gettext("for the owner")
        "reporter" -> gettext("for the reporter")
        _ -> role
      end

    gettext("level %{level}, %{role}", level: level, role: role_label)
  end

  def event_detail("owner_removed", %{"action" => action} = detail) do
    reason = detail["reason"]

    action_label =
      case action do
        "deactivate" -> gettext("deactivated")
        "delete" -> gettext("deleted")
        other -> other
      end

    if reason in [nil, ""],
      do: action_label,
      else: gettext("%{action} (%{reason})", action: action_label, reason: reason)
  end

  def event_detail("relationship_severed", detail) do
    [
      detail["connection"] && gettext("connection"),
      (detail["follows"] || 0) > 0 && gettext("%{count} follows", count: detail["follows"]),
      detail["conversation"] && gettext("messages")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  def event_detail(_action, _detail), do: nil

  defdelegate category_label(category), to: VutuvWeb.ReportHTML
end
