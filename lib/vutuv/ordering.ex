defmodule Vutuv.Ordering do
  @moduledoc """
  The user-defined display order shared by the orderable profile sections:
  phone numbers, addresses, social media accounts, email addresses and links
  (`urls`).

  Each of those schemas carries a nullable `:position` integer that is set
  programmatically — on create (appended at the end) and through the reorder /
  move actions below — **never** cast from user params. NULLs sort last, so a
  legacy or mid-deploy row falls back to its creation order until it is
  reordered.

  Every write is scoped to the owning `user_id`, so a stray, stale or forged id
  can never renumber another member's rows. The owner's drag-and-drop tool and
  arrow buttons (`VutuvWeb.SectionReorderLive`) both route through here.
  """

  import Ecto.Query

  alias Vutuv.Repo

  @doc """
  Order a queryable by `position` (NULLs last), then `id` (creation order) as a
  stable tiebreaker. Each schema's `ordered/1` delegates here so the rule lives
  in one place. Accepts a base query so callers can scope to one user first.
  """
  def by_position(query) do
    from(x in query, order_by: [asc_nulls_last: x.position, asc: x.id])
  end

  @doc "The append position (max + 1) for a new `schema` row of `user_id`."
  def next_position(schema, user_id) do
    (Repo.aggregate(from(x in schema, where: x.user_id == ^user_id), :max, :position) || 0) + 1
  end

  @doc "`user_id`'s row ids of `schema`, in the current display order."
  def ordered_ids(schema, user_id) do
    Repo.all(
      from(x in schema,
        where: x.user_id == ^user_id,
        order_by: [asc_nulls_last: x.position, asc: x.id],
        select: x.id
      )
    )
  end

  @doc """
  Persist `submitted_ids` (a drag-and-drop order) as positions 1..n. Only the
  owner's own ids count: a forged or stale foreign id is dropped, and any id the
  client did not mention is appended in its current order, so positions stay a
  clean 1..n over exactly the owner's rows.
  """
  def reorder(schema, user_id, submitted_ids) do
    owned = ordered_ids(schema, user_id)
    owned_set = MapSet.new(owned)

    submitted = submitted_ids |> Enum.filter(&MapSet.member?(owned_set, &1)) |> Enum.uniq()
    remaining = Enum.reject(owned, &(&1 in submitted))

    persist_order(schema, user_id, submitted ++ remaining)
  end

  @doc """
  Nudge one row up or down by a single step (the arrow buttons): swap it with
  its neighbour in the current order and renumber 1..n. An out-of-range move
  (the top row up, the bottom row down) is a no-op.
  """
  def move(schema, user_id, id, direction) when direction in [:up, :down] do
    schema
    |> ordered_ids(user_id)
    |> swap(id, direction)
    |> then(&persist_order(schema, user_id, &1))
  end

  # Write positions 1..n for the given ids, scoped to the owner so a stray id
  # can never touch another member's row. One transaction keeps the order
  # consistent if a write fails midway.
  defp persist_order(schema, user_id, ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {id, position} ->
        from(x in schema, where: x.id == ^id and x.user_id == ^user_id)
        |> Repo.update_all(set: [position: position])
      end)
    end)
  end

  defp swap(ids, id, direction) do
    case Enum.find_index(ids, &(&1 == id)) do
      nil ->
        ids

      idx ->
        target = if direction == :up, do: idx - 1, else: idx + 1

        if target in 0..(length(ids) - 1) do
          ids
          |> List.replace_at(idx, Enum.at(ids, target))
          |> List.replace_at(target, Enum.at(ids, idx))
        else
          ids
        end
    end
  end
end
