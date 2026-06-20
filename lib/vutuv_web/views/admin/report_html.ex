defmodule VutuvWeb.Admin.ReportHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/report/*")

  @doc """
  The report's metrics as `{label, value}` rows, in the order both the page
  and the email list them. Keeps the labels in one place so the table stays in
  sync with the struct.
  """
  def metrics(report) do
    [
      {gettext("New confirmed registrations (by PIN)"), report.registrations},
      {gettext("Posts"), report.posts},
      {gettext("Reposts"), report.reposts},
      {gettext("Likes"), report.likes},
      {gettext("Bookmarks"), report.bookmarks},
      {gettext("Bounces"), report.bounces},
      {gettext("Deactivated addresses"), report.deactivations},
      {gettext("Frozen accounts"), report.freezes},
      {gettext("Thawed accounts"), report.thaws}
    ]
  end
end
