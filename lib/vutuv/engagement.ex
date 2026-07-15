defmodule Vutuv.Engagement do
  @moduledoc """
  The idempotent "toggle a join row" insert shared by the engagement actions:
  post likes / bookmarks / reposts (`Vutuv.Posts`) and member likes / bookmarks
  (`Vutuv.Social`). Ids are minted in code, so the inserted row count, not a
  returned id, is what tells a fresh insert from the idempotent repeat.

  On top of the kernel sits the config-driven **like/bookmark fabric** the two
  symmetric subjects — job postings and organization pages — share verbatim:
  engage/disengage with a fresh-change-only broadcast, the count+flags map for
  the action bar, and the per-subject counter topic. Posts and member saves
  keep their own wrappers around the bare kernel (their guards, notifications
  and return shapes genuinely diverge — a deliberate non-merge).
  """
  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.UUIDv7

  @doc """
  Inserts a join row (stamped with a v7 id and `inserted_at`/`updated_at`)
  unless the unique `conflict_target` already holds it. `fields` are the row's
  own columns (e.g. `%{user_id: ..., post_id: ...}`). Returns `{:inserted, row}`
  on a fresh insert, or `:exists` when it was already there.
  """
  def insert_if_new(schema, fields, conflict_target) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    row = Map.merge(fields, %{id: UUIDv7.generate(), inserted_at: now, updated_at: now})

    case Repo.insert_all(schema, [row],
           on_conflict: :nothing,
           conflict_target: conflict_target,
           returning: true
         ) do
      {0, _} -> :exists
      {1, [inserted]} -> {:inserted, inserted}
    end
  end

  # ── the symmetric like/bookmark fabric ──────────────────────────────────
  #
  # `cfg` names everything that differs per subject:
  #
  #   * :fk            — the join tables' subject column, which doubles as the
  #                      id key in both broadcast payloads (:job_posting_id /
  #                      :organization_id)
  #   * :like_schema   — the like join schema (the public counter)
  #   * :topic_prefix  — the per-subject PubSub topic, "<prefix>:<id>"
  #   * :counters_msg  — the tuple name of the absolute-count broadcast on the
  #                      subject topic
  #   * :changed_msg   — the tuple name of the actor-topic broadcast the
  #                      /bookmarks hub consumes
  #
  # The tuple names and payload keys are pattern-matched by the subject's
  # LiveViews (show pages, the board, PostLive.Saved) — a rename is a breaking
  # contract change, never do it casually.

  @doc """
  Adds one engagement row for `user_id` on the subject, broadcasting the fresh
  counter + the actor-topic change only when it really was new. Returns
  `{:ok, row}` or `{:ok, :noop}` for the idempotent repeat.
  """
  def engage(schema, kind, user_id, subject_id, cfg) do
    fields = Map.new([{:user_id, user_id}, {cfg.fk, subject_id}])

    case insert_if_new(schema, fields, [cfg.fk, :user_id]) do
      :exists ->
        {:ok, :noop}

      {:inserted, row} ->
        broadcast_engagement(cfg, kind, user_id, subject_id, true)
        {:ok, row}
    end
  end

  @doc "Removes the engagement row, broadcasting only a real removal. Returns `:ok`."
  def disengage(schema, kind, user_id, subject_id, cfg) do
    {count, _} =
      Repo.delete_all(
        from(e in schema, where: field(e, ^cfg.fk) == ^subject_id and e.user_id == ^user_id)
      )

    if count > 0, do: broadcast_engagement(cfg, kind, user_id, subject_id, false)
    :ok
  end

  @doc """
  Public like count plus the viewer's own `liked?`/`bookmarked?` flags for the
  action bar. An anonymous viewer gets `false` flags.
  """
  def subject_engagement(bookmark_schema, subject_id, viewer, cfg) do
    viewer_id = viewer && viewer.id

    %{
      likes: like_count(cfg, subject_id),
      liked?: viewer_id != nil and engaged?(cfg.like_schema, cfg.fk, subject_id, viewer_id),
      bookmarked?: viewer_id != nil and engaged?(bookmark_schema, cfg.fk, subject_id, viewer_id)
    }
  end

  @doc "Subscribes the calling process to the subject's live counter topic."
  def subscribe(subject_id, cfg),
    do: Phoenix.PubSub.subscribe(Vutuv.PubSub, topic(subject_id, cfg))

  @doc "The subject's PubSub topic (also carries the subject's non-counter pings)."
  def topic(subject_id, cfg), do: "#{cfg.topic_prefix}:#{subject_id}"

  defp like_count(cfg, subject_id) do
    cfg.like_schema
    |> where([l], field(l, ^cfg.fk) == ^subject_id)
    |> Repo.aggregate(:count, :id)
  end

  defp engaged?(schema, fk, subject_id, user_id) do
    schema
    |> where([e], field(e, ^fk) == ^subject_id and e.user_id == ^user_id)
    |> Repo.exists?()
  end

  # The per-subject topic carries the absolute like count to every open page;
  # the actor's activity topic tells the /bookmarks hub to add or drop a card.
  defp broadcast_engagement(cfg, kind, user_id, subject_id, active?) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      topic(subject_id, cfg),
      {cfg.counters_msg, Map.new([{cfg.fk, subject_id}, {:likes, like_count(cfg, subject_id)}])}
    )

    Vutuv.Activity.broadcast(
      user_id,
      {cfg.changed_msg, Map.new([{:kind, kind}, {cfg.fk, subject_id}, {:active?, active?}])}
    )
  end
end
