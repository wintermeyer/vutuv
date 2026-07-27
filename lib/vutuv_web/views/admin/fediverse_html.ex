defmodule VutuvWeb.Admin.FediverseHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers, only: [member_name: 1]

  embed_templates("../../templates/admin/fediverse/*")

  @doc """
  What a takedown row means, in words. The stored `action` values are the closed
  set `Vutuv.Fediverse.NoteEvent.actions/0` holds; an unknown one still renders
  something rather than leaking a raw string at the operator.
  """
  def note_event_label(%{action: "reported"}), do: gettext("Reported as not appropriate")

  # Named apart from a reported reply (issue #1161): a reply sat under one
  # member's post, a cached post is shared by everybody who follows its author,
  # so this one removal emptied it out of all of their feeds.
  def note_event_label(%{action: "reported_post"}),
    do: gettext("Cached post reported, removed for everyone here")

  def note_event_label(%{action: "removed_by_member"}), do: gettext("Removed by the member")

  def note_event_label(%{action: "flagged"}), do: gettext("Reported to the origin server")
  def note_event_label(_event), do: gettext("Taken down")

  @doc """
  What an undelivered takedown was trying to do, in words (issue #1102). The
  stored types are the closed allowlist `Vutuv.Fediverse` records give-ups for.
  """
  def takedown_label(%{activity_type: "Delete"}), do: gettext("Asked to delete a copy")
  def takedown_label(%{activity_type: "Flag"}), do: gettext("Passed a report on")
  def takedown_label(_failure), do: gettext("Withdrawal request")
end
