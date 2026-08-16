defmodule Vutuv.Translations.TranslationJob do
  @moduledoc """
  One on-demand translation request — both the durable queue entry and, once
  resolved, the record of how it went (the `Vutuv.Moderation.ImageScan`
  row-is-the-job pattern).

  A `pending` row is work waiting for the worker, `running` is in flight,
  `done` produced (or refreshed) a `Vutuv.Translations.Translation` row, and
  `failed` means the strike cap was reached — the card keeps showing the
  original. A job exists only because a reader asked for that translation;
  nothing enqueues in bulk. Subject columns mirror `translations` (exactly
  one set, CHECK-enforced). All fields are set programmatically by
  `Vutuv.Translations` — there is no user-facing changeset.
  """

  use VutuvWeb, :model

  @open_statuses ~w(pending running)

  schema "translation_jobs" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)
    belongs_to(:note, Vutuv.Fediverse.Note)

    field(:target_language, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)

    timestamps()
  end

  @doc "The statuses that count as unfinished work (mirrors the partial unique indexes)."
  def open_statuses, do: @open_statuses
end
