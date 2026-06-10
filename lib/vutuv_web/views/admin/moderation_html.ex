defmodule VutuvWeb.Admin.ModerationHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Moderation.Case

  embed_templates("../../templates/admin/moderation/*")

  def status_badge(%Case{status: "escalated"}), do: gettext("Escalated")
  def status_badge(%Case{status: "flagged"}), do: gettext("Flagged")
  def status_badge(%Case{status: status}), do: status

  def content_type_label("post"), do: gettext("Post")
  def content_type_label("message"), do: gettext("Private message")
  def content_type_label("user"), do: gettext("Profile")

  defdelegate category_label(category), to: VutuvWeb.ReportHTML
end
