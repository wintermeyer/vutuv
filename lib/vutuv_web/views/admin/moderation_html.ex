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

  def content_type_label("post"), do: gettext("Post")
  def content_type_label("message"), do: gettext("Private message")
  def content_type_label("user"), do: gettext("Profile")
  def content_type_label("company"), do: gettext("Company page")

  # The audit-log line for one moderation event (see Vutuv.Moderation.Event).
  def event_label("report_filed"), do: gettext("Report filed")
  def event_label("content_frozen"), do: gettext("Content frozen")
  def event_label("relationship_severed"), do: gettext("Reporter and owner separated")
  def event_label("relationship_restored"), do: gettext("Separation lifted")
  def event_label("owner_disputed"), do: gettext("Owner disputed the report")
  def event_label("content_edited"), do: gettext("Owner edited the content")
  def event_label("content_deleted"), do: gettext("Content deleted")
  def event_label("escalated_deadline"), do: gettext("Escalated - the 72h deadline passed")
  def event_label("upheld"), do: gettext("Report upheld")
  def event_label("rejected"), do: gettext("Report rejected")
  def event_label("owner_removed"), do: gettext("Account removed")
  def event_label("strike_issued"), do: gettext("Strike issued")
  def event_label("evidence_captured"), do: gettext("Evidence screenshot captured")
  def event_label(other), do: other

  # The small action-specific facts an event carries (JSONB, string keys).
  def event_detail("report_filed", %{"category" => category}) when is_binary(category),
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
