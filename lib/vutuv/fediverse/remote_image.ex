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

  # Four is what the networks out there let an author attach, and it is as many
  # as a card can show without becoming a gallery page.
  @max_per_post 4

  # Remote URIs are unbounded in theory; the unique index over
  # (remote_post_id, source_uri) makes this a btree key, so cap it in bytes.
  @max_uri_bytes 2_048

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

    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    timestamps(updated_at: false)
  end

  @doc "How many pictures one remote post may carry."
  def max_per_post, do: @max_per_post

  @doc """
  Whether this picture may be rendered at all: the gate cleared it and the file
  is here. The one chokepoint every surface reads, so "has a file" can never
  drift from "was allowed".
  """
  def released?(%__MODULE__{file: file, moderation: moderation}),
    do: is_binary(file) and file != "" and moderation == "approved"

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
      :sensitive
    ])
    |> validate_required([:source_uri])
    |> validate_length(:source_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:alt, max: @max_alt)
    |> unique_constraint([:remote_post_id, :source_uri])
  end
end
