defmodule Vutuv.Translations.TranslationJob do
  @moduledoc """
  One on-demand translation request — both the durable queue entry and, once
  resolved, the record of how it went (the `Vutuv.Moderation.ImageScan`
  row-is-the-job pattern).

  A `pending` row is work waiting for the worker, `running` is in flight,
  `done` produced (or refreshed) a `Vutuv.Translations.Translation` row, and
  `failed` means the strike cap was reached — the card keeps showing the
  original. Subject columns mirror `translations` (exactly one set,
  CHECK-enforced). All fields are set programmatically by
  `Vutuv.Translations` — there is no user-facing changeset.

  A job is opened either by a reader tapping Translate or by the background
  pre-translation sweep, and `priority` is the difference: the drain runs
  **lower first**, so a reader never queues behind the sweep's backlog. The
  two share the row — a reader asking for something the sweep already queued
  lands on that same job and *promotes* it rather than opening a second one.
  """

  use VutuvWeb, :model

  @open_statuses ~w(pending running)

  # Lower runs first. Only these two values are ever written; the gap between
  # them is room for a third rank nobody has needed yet.
  @reader_priority 0
  @background_priority 50

  schema "translation_jobs" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)
    belongs_to(:note, Vutuv.Fediverse.Note)

    field(:target_language, :string)
    field(:status, :string, default: "pending")
    field(:priority, :integer, default: @reader_priority)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)

    timestamps()
  end

  @doc "The statuses that count as unfinished work (mirrors the partial unique indexes)."
  def open_statuses, do: @open_statuses

  @doc """
  The rank of a job somebody is waiting for. The column's DEFAULT too, so a
  release one deploy behind — which inserts without this column and whose jobs
  are all reader requests — keeps its right of way through the switch window.
  """
  def reader_priority, do: @reader_priority

  @doc "The rank of a job the background pre-translation sweep opened."
  def background_priority, do: @background_priority
end
