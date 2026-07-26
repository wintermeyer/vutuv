defmodule Vutuv.Fediverse.NoteEvent do
  @moduledoc """
  One remote reply taken down by a member (issue #1069): they removed it from
  their own post, or reported it as not appropriate — which deletes it at once,
  with no case workflow, because the note is a cache of something that still
  exists at its origin.

  A report also writes a second `"flagged"` row when the report actually reached
  that origin as an ActivityPub `Flag` (issue #1102), so the operator can tell a
  takedown that only happened here from one the other server was told about.

  The row exists so the operator can answer one question: **is this one troll,
  or is this server the problem?** That is the decision the blocklist at
  `/admin/fediverse` acts on, and it needs the host, a way to tell repeat actors
  apart, and a count over time. Nothing else.

  So, following the precedent `Vutuv.Fediverse.FollowerPrune` set in #1072, this
  keeps **no content and no URIs**. Retaining a stranger's words after deleting
  their note would make the deletion we just promised untrue, and retaining their
  actor URI would keep an online identifier of somebody whose words we removed.
  `actor_digest` is a keyed HMAC of the actor URI (peppered from
  `secret_key_base`, per the project rule that a bare hash of a guessable value
  is not privacy), which groups repeat offenders without holding the identifier.

  `user_id` (whose post it sat under) and `actor_id` (who acted) are plain
  values, not associations, like the deliverability and admin-action ledgers:
  an audit row must stay readable after the rows it references are gone. Rows
  are written by `Vutuv.Fediverse` only, never built from user params.

  Automatic deletions are deliberately **not** recorded here. An expiry sweep, a
  server block or an upstream `Delete` can remove thousands of rows at once and
  would drown the signal; those are reported in aggregate to the log, the way
  `Vutuv.Fediverse.FollowerPruner` reports.
  """

  use VutuvWeb, :model

  @actions ~w(reported removed_by_member flagged)

  @doc "The closed set of `action` values this ledger records."
  def actions, do: @actions

  schema "fediverse_note_events" do
    field(:action, :string)
    field(:host, :string)
    field(:actor_digest, :string)
    field(:audience, :string)
    field(:user_id, :binary_id)
    field(:actor_id, :binary_id)

    timestamps(updated_at: false)
  end
end
