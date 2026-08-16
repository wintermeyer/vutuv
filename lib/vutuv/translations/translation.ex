defmodule Vutuv.Translations.Translation do
  @moduledoc """
  One cached translation of one subject into one target language.

  The subject is exactly one of a local post, a cached remote post, or a
  cached remote reply (CHECK-enforced nullable triple — read it through
  `Vutuv.Translations.subject/1`, never by picking a column). `source_sha256`
  binds the row to the exact source text it translated: when the source is
  edited the hash no longer matches, the row counts as stale, and the next
  request re-translates. All fields are set programmatically by
  `Vutuv.Translations` — there is no user-facing changeset.
  """

  use VutuvWeb, :model

  schema "translations" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)
    belongs_to(:note, Vutuv.Fediverse.Note)

    field(:target_language, :string)
    # As the model reported it ("de", "en", or "und" when it could not tell).
    field(:source_language, :string)
    field(:body, :string)
    # The translated content warning; only remote content carries one.
    field(:summary, :string)
    field(:model, :string)
    field(:source_sha256, :string)

    timestamps()
  end
end
