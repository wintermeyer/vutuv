defmodule Vutuv.Tags.ExternalPost do
  @moduledoc """
  One post another server's public tag timeline carried (issue #2126): plain
  text, a link to the original, and who wrote it.

  **Text and a link, never a picture.** Every foreign image would have to go
  through the AI image gate, and on a busy tag most posts carry one; the
  language arrives declared, so even knowing what language this is costs no
  model call. `text` is already reduced to plain text by
  `Vutuv.Tags.ExternalTagClient` (through `Vutuv.RemoteHtml`, the one place
  remote HTML becomes something we keep) — never render it with `raw/1`.

  Deliberately **not** a row in `fediverse_posts` — see the migration for what a
  cached ActivityPub object drags behind it.

  Nothing here is user-writable — it is server-writable, which carries the same
  hazard and one more besides. A value too long for its column raises Postgres
  22001 on a path with no form in front of it, and **`validate_length/3` cannot
  be the guard against that**: it counts graphemes while `varchar(n)` counts
  codepoints, so 100 ZWJ family emoji pass a `max: 255` check as 100 characters
  and reach the column as 700. Hence the two rules here. A value that is
  somebody's **chosen spelling of themselves** — their display name, their
  address — goes in a `text` column and is clamped for display rather than
  refused, because dropping a stranger's post over the length of their name is
  the wrong answer. A value that is a **token** keeps its bounded column and is
  capped in **bytes**, which in UTF-8 are never fewer than the codepoints the
  column counts, so the check is conservative and can never be overrun.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [scrub_nul: 1]

  alias Vutuv.Fediverse.BlockedInstance

  # The clamp the client applies (`Vutuv.SocialFeed.Post.truncate/1`) is 500
  # characters; this is the backstop under it, on a `text` column.
  @max_text 1_000

  # What a display identity may take up here. Not a column limit — those two are
  # `text` — but the ceiling on what a stranger's server may park in a row this
  # installation shows: `Vutuv.Tags.ExternalTagClient` clamps to it, and a value
  # that somehow arrives longer is refused rather than stored whole.
  @max_display 255

  # Bounded columns, capped in bytes. `remote_id` also rides a btree unique
  # index, so it cannot be widened to text without weighing that entry against
  # Postgres' ~2704-byte limit.
  @max_id 255
  @max_language 32

  # Both addresses live in `text` columns, so this is not the column's limit —
  # it is the ceiling on what a stranger's server may park here at all, the
  # same 2048 bytes the fediverse URI sources cap at.
  @max_url 2_048

  schema "external_tag_posts" do
    field(:source, :string)
    field(:remote_id, :string)
    field(:url, :string)
    field(:text, :string)
    field(:author_name, :string)
    field(:author_acct, :string)
    field(:author_url, :string)
    field(:language, :string)
    field(:published_at, :utc_datetime)

    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  @fields ~w(tag_id source remote_id url text author_name author_acct author_url
             language published_at)a
  @required ~w(tag_id source remote_id url text published_at)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @fields)
    # A NUL byte in a remote string is not a length problem and no length check
    # would catch it: Postgres refuses one in a text value outright, so it is
    # the other way a display name can raise inside the insert.
    |> scrub_nul()
    |> validate_required(@required)
    |> validate_length(:source, max: BlockedInstance.max_host(), count: :bytes)
    |> validate_length(:remote_id, max: @max_id, count: :bytes)
    |> validate_length(:language, max: @max_language, count: :bytes)
    |> validate_length(:url, max: @max_url, count: :bytes)
    |> validate_length(:author_url, max: @max_url, count: :bytes)
    |> validate_length(:text, max: @max_text)
    |> validate_length(:author_name, max: @max_display, count: :bytes)
    |> validate_length(:author_acct, max: @max_display, count: :bytes)
    |> unique_constraint(:remote_id, name: :external_tag_posts_tag_id_source_remote_id_index)
    |> foreign_key_constraint(:tag_id)
  end

  @doc "How much of a display identity is kept — the client clamps to it."
  def max_display, do: @max_display

  @doc "The longest token this table will store as a remote id."
  def max_id, do: @max_id

  @doc "The longest declared language code this table will store."
  def max_language, do: @max_language
end
