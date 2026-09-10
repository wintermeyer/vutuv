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
  hazard: an oversized value raises Postgres 22001 on a path with no form in
  front of it, so every column has its `validate_length` and an invalid status
  is dropped rather than allowed to abort the batch.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.BlockedInstance

  # The clamp the client applies (`Vutuv.SocialFeed.Post.truncate/1`) is 500
  # characters; this is the backstop under it, on a `text` column.
  @max_text 1_000
  @max_id 255
  @max_name 255
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
    |> validate_required(@required)
    |> validate_length(:source, max: BlockedInstance.max_host())
    |> validate_length(:remote_id, max: @max_id)
    |> validate_length(:url, max: @max_url)
    |> validate_length(:author_url, max: @max_url)
    |> validate_length(:text, max: @max_text)
    |> validate_length(:author_name, max: @max_name)
    |> validate_length(:author_acct, max: @max_name)
    |> validate_length(:language, max: @max_language)
    |> unique_constraint(:remote_id, name: :external_tag_posts_tag_id_source_remote_id_index)
    |> foreign_key_constraint(:tag_id)
  end
end
