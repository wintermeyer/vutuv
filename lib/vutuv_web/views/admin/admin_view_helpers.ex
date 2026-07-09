defmodule VutuvWeb.Admin.AdminViewHelpers do
  @moduledoc """
  Small formatting helpers shared across the admin HTML views. Imported by the
  admin `*HTML` modules so a single definition serves every admin template.
  """

  @doc """
  Short `YYYY-MM-DD HH:MM` timestamp for admin listings and log tables.

  A `nil` renders as an empty string, so a not-yet-set time (a draft
  newsletter's `sent_at`) shows blank instead of raising.
  """
  def fmt(nil), do: ""
  def fmt(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
end
