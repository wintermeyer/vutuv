defmodule VutuvWeb.Admin.ReportHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/report/*")

  # Every metric in table/detail order. Drives metrics/1 and the detail
  # sections, so the two stay in sync and each label lives in exactly one place.
  @metric_order [
    :registrations,
    :posts,
    :reposts,
    :likes,
    :bookmarks,
    :fediverse_followers,
    :bounces,
    :deactivations,
    :freezes,
    :thaws,
    :spam_removals
  ]

  @doc """
  The report's metrics as `{label, value}` rows, in the order the page lists
  them. Keeps the labels in one place (`metric_label/1`) so the summary table,
  the detail sections and the struct stay in sync.
  """
  def metrics(report) do
    Enum.map(@metric_order, fn key -> {metric_label(key), Map.fetch!(report, key)} end)
  end

  @doc "The localized heading for one metric, shared by the table and the detail sections."
  def metric_label(:registrations), do: gettext("New confirmed registrations (by PIN)")
  def metric_label(:posts), do: gettext("Posts")
  def metric_label(:reposts), do: gettext("Reposts")
  def metric_label(:likes), do: gettext("Likes")
  def metric_label(:bookmarks), do: gettext("Bookmarks")
  def metric_label(:fediverse_followers), do: gettext("New Fediverse followers")
  def metric_label(:bounces), do: gettext("Bounces")
  def metric_label(:deactivations), do: gettext("Deactivated addresses")
  def metric_label(:freezes), do: gettext("Frozen accounts")
  def metric_label(:thaws), do: gettext("Thawed accounts")
  def metric_label(:spam_removals), do: gettext("Accounts removed as spam")
end
