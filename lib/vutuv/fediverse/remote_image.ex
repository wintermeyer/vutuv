defmodule Vutuv.Fediverse.RemoteImage do
  @moduledoc """
  One picture attached to a post by an account somebody here follows (issue
  #1163).

  The reply cards took the deliberate stance that no third party's picture is
  copied here: initials and a link out. That is right for a stranger who
  answered a member's post, and wrong for an account somebody chose to follow —
  for a reader who follows photographers, the picture *is* the post, and a card
  reading "text plus a link" is not the thing they subscribed to.

  So the bytes are fetched and stored, and then held invisible until the AI
  image gate clears them, exactly like a member's own upload
  (`Vutuv.Moderation.ImageScans`). Nothing an unknown server sends us is
  published sight unseen. Two independent conditions decide what a reader gets:

    * `moderation` — our gate. Only `"approved"` renders at all.
    * `sensitive` — the **author's** own flag, or the post's content warning.
      It renders blurred behind a click. Deliberately not overridable by the
      gate: our model judging a picture safe does not overrule the person who
      published it asking for it to be covered.

  There is no private original (the `Vutuv.ReviewCover` exception, for the same
  reason): this is somebody else's picture, quoted beside their post, so we keep
  the one derived version we actually show and nothing beyond it.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [scrub_nul: 1]

  # Four is what the networks out there let an author attach, and it is as many
  # as a card can show without becoming a gallery page.
  @max_per_post 4

  # Remote URIs are unbounded in theory; the unique index over
  # (remote_post_id, source_uri) makes this a btree key, so cap it in bytes.
  @max_uri_bytes 2_048

  # Refused downloads before the picture is given up on (issue #1803). Small on
  # purpose: this exists to survive a blip or a deploy that killed the first
  # attempt, not to argue with a server that has made up its mind.
  @max_fetch_failures 5

  # An alt text is a description, not an essay. Generous, because the point of
  # keeping it is that somebody who cannot see the picture still can read it.
  @max_alt 2_000

  schema "fediverse_post_images" do
    field(:source_uri, :string)
    field(:position, :integer, default: 0)
    field(:alt, :string)
    field(:file, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:moderation, :string)
    field(:sensitive, :boolean, default: false)

    # What the download has tried (issue #1803). `Vutuv.Fediverse.MediaRefetcher`
    # is the only writer; see `Vutuv.Fediverse.Media`.
    field(:fetch_failures, :integer, default: 0)
    field(:fetch_attempted_at, :utc_datetime)

    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    timestamps(updated_at: false)
  end

  @doc "How many pictures one remote post may carry."
  def max_per_post, do: @max_per_post

  @doc """
  How many refused downloads a picture gets before nobody asks again (issue
  #1803). The column's own bound, so the schema that declares `fetch_failures`
  is what says when it is spent.
  """
  def max_fetch_failures, do: @max_fetch_failures

  @doc """
  Whether this picture may be rendered at all: the gate cleared it and the file
  is here. The one chokepoint every surface reads, so "has a file" can never
  drift from "was allowed".
  """
  def released?(%__MODULE__{moderation: moderation} = image),
    do: stored?(image) and moderation == "approved"

  @doc """
  Whether this picture is **not coming** (issue #1803): the gate refused it, or
  its bytes never arrived and `Vutuv.Fediverse.MediaRefetcher` has stopped
  asking.

  Two columns, because the two answers come from different places and only one
  of them is a verdict. `moderation` is what the **gate** decided — `"rejected"`
  now, `nil` in the rows it wrote before that word existed. `fetch_failures` is
  what the **download** managed, and it is deliberately not folded into the
  verdict column: an installation running without the vision model records
  every picture `"approved"` on the spot (`ImageScans.initial_state/0`), so a
  failed download there carries an approval and no file, and a terminal state
  kept in `moderation` would have missed that whole class of installation.

  The card asks this **before** it asks whether to wait. The two look identical
  in the data — no file, not approved — and reading the second question first
  is what left members watching a check that was never going to run, on some
  rows since 2026-08-03.
  """
  def unavailable?(%__MODULE__{} = image), do: not stored?(image) and given_up?(image)

  @doc """
  What a card should draw for this picture, in the order the questions have to
  be asked (issue #1803).

  One function rather than a chain of `if`s at the call site, because the order
  **is** the bug: "is it still being checked" answers yes for a picture that was
  refused three weeks ago, so it may only be asked once "is it coming at all"
  has said yes.
  """
  def display_state(%__MODULE__{} = image) do
    cond do
      unavailable?(image) -> :unavailable
      not released?(image) -> :waiting
      blurred?(image) -> :sensitive
      true -> :ready
    end
  end

  defp stored?(%__MODULE__{file: file}), do: is_binary(file) and file != ""

  defp given_up?(%__MODULE__{moderation: moderation, fetch_failures: failures}),
    do: moderation in [nil, "rejected"] or (failures || 0) >= @max_fetch_failures

  @doc """
  Whether it renders behind a click. The author's flag, never our verdict —
  see the moduledoc.
  """
  def blurred?(%__MODULE__{sensitive: sensitive}), do: sensitive == true

  def changeset(%__MODULE__{} = image, attrs) do
    image
    |> cast(attrs, [
      :source_uri,
      :position,
      :alt,
      :file,
      :width,
      :height,
      :moderation,
      :sensitive,
      :fetch_failures,
      :fetch_attempted_at
    ])
    # `source_uri` and the author's `alt` come out of the attachment JSON, and a
    # NUL in either raises on insert (issue #1767).
    |> scrub_nul()
    |> validate_required([:source_uri])
    |> validate_length(:source_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:alt, max: @max_alt)
    |> unique_constraint([:remote_post_id, :source_uri])
  end
end
