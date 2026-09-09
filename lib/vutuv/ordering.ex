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

  @doc """
  The ids a queryable holds, in the current display order.

  `ordered_ids/1` takes an **already scoped** queryable, which is what makes
  this module serve a second owner shape: `Vutuv.PressKit`'s rows belong to a
  member **or** a page and sit on one of two shelves, so its scope is a party
  and a boolean rather than a `user_id`. `ordered_ids/2` is the profile
  sections' own face on it.
  """
  def ordered_ids(query) do
    from(x in query, select: x.id) |> by_position() |> Repo.all()
  end

  def ordered_ids(schema, user_id), do: ordered_ids(scoped(schema, user_id))

  @doc """
  Persist `submitted_ids` (a drag-and-drop order) as positions 1..n. Only the
  owner's own ids count: a forged or stale foreign id is dropped, and any id the
  client did not mention is appended in its current order, so positions stay a
  clean 1..n over exactly the owner's rows.
  """
  def reorder(schema, user_id, submitted_ids) do
    query = scoped(schema, user_id)

    query
    |> ordered_ids()
    |> arrange(submitted_ids)
    |> then(&persist_order(query, &1, 1))
  end

  @doc """
  Writes `ordered_ids` as consecutive positions from `start`, each update scoped
  to `query` so a stray id can never touch a row outside it. One transaction, so
  an interruption leaves the list ordered rather than half ordered.

  `start` is a parameter because the two callers disagree and both are right:
  the profile sections number from 1, while a press kit numbers from 0 —
  `Vutuv.PressKit.create/4` has handed out `count` as the next position since
  #2083, and its download name reads `position + 1`, so renumbering a shelf from
  1 would rename the hero's file.
  """
  def persist_order(query, ordered_ids, start) when is_integer(start) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index(start)
      |> Enum.each(fn {id, position} ->
        from(x in query, where: x.id == ^id) |> Repo.update_all(set: [position: position])
      end)
    end)
  end

  @doc """
  The order a drag-and-drop payload actually means, over the ids that really
  belong to the owner: the submitted ones in the order the client sent, then
  everything it left out in its current order. A forged or stale foreign id is
  dropped, so a payload can rearrange the list but never change what is in it.

  Public and free of the database on purpose: `Vutuv.PressKit` numbers its two
  shelves itself, and this is the half of the rule both spellings share.
  """
  def arrange(owned_ids, submitted_ids) do
    owned = MapSet.new(owned_ids)
    submitted = submitted_ids |> Enum.filter(&MapSet.member?(owned, &1)) |> Enum.uniq()

    submitted ++ Enum.reject(owned_ids, &(&1 in submitted))
  end

  @doc """
  One row nudged a single step (the arrow buttons): swapped with its neighbour
  in the current order. An out-of-range move — the top row up, the bottom row
  down — and an id that is not in the list are both the list unchanged.
  """
  def swap(ids, id, direction) when direction in [:up, :down] do
    case Enum.find_index(ids, &(&1 == id)) do
      nil ->
        ids

      idx ->
        target = if direction == :up, do: idx - 1, else: idx + 1

        if target in 0..(length(ids) - 1)//1 do
          ids
          |> List.replace_at(idx, Enum.at(ids, target))
          |> List.replace_at(target, Enum.at(ids, idx))
        else
          ids
        end
    end
  end

  @doc """
  Nudge one row up or down by a single step (the arrow buttons): swap it with
  its neighbour in the current order and renumber 1..n. An out-of-range move
  (the top row up, the bottom row down) is a no-op.
  """
  def move(schema, user_id, id, direction) when direction in [:up, :down] do
    query = scoped(schema, user_id)

    query
    |> ordered_ids()
    |> swap(id, direction)
    |> then(&persist_order(query, &1, 1))
  end

  # One member's rows of one schema — this module's own owner shape, and the
  # only place it is spelled.
  defp scoped(schema, user_id), do: from(x in schema, where: x.user_id == ^user_id)
end
