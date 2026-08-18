defmodule Vutuv.Identity.Query do
  @moduledoc """
  Query macros for the nullable `user_id | organization_id` column pair
  (issue #1416) — the query half of the `Vutuv.Identity` seam.

  Fourteen tables carry the pair, and its NULL semantics produced the
  milestone's whole silent-failure class: `x NOT IN (…, NULL)` is never true,
  `x == ^nil` raises, and a gate written for one kind waves the other through.
  These macros spell the idiom once, so a call site cannot forget the side it
  did not think of.
  """

  import Vutuv.Organizations.Query, only: [organization_public_row: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization

  @doc """
  Whether the row's `user_id | organization_id` pair names `party` (a `%User{}`
  or `%Organization{}`, passed as a bound variable — it is read twice).

  Expands to one static SQL shape for both kinds,
  `(user_id = $u OR organization_id = $o)`, with the other kind's parameter
  NULL: `col = NULL` is never true in SQL, so the wrong-kind arm can never
  match — and going through `fragment/1` is what allows the NULL parameter at
  all, since Ecto refuses `== ^nil` at runtime.
  """
  defmacro party_is(row, party) do
    quote do
      fragment(
        "(? = ? OR ? = ?)",
        unquote(row).user_id,
        type(^Vutuv.Identity.Query.user_side(unquote(party)), Vutuv.UUIDv7),
        unquote(row).organization_id,
        type(^Vutuv.Identity.Query.organization_side(unquote(party)), Vutuv.UUIDv7)
      )
    end
  end

  @doc """
  LEFT-joins both parties of a column pair onto `query`'s root binding: the
  member first, the page second (positionally, in that order). Pass the pair's
  column names, e.g. `join_party(query, :follower_id, :follower_organization_id)`.
  """
  defmacro join_party(query, user_field, organization_field) do
    quote do
      unquote(query)
      |> Ecto.Query.join(:left, [x], u in Vutuv.Accounts.User,
        on: u.id == field(x, unquote(user_field))
      )
      |> Ecto.Query.join(:left, [x], o in Vutuv.Organizations.Organization,
        on: o.id == field(x, unquote(organization_field))
      )
    end
  end

  @doc """
  Whether a `join_party/3` pair resolves to a party worth showing: any member
  row (the row existing is the whole test — no moderation gate, matching what
  the pre-#1336 inner join to `users` amounted to), or a page a reader may
  open (`Vutuv.Organizations.Query.organization_public_row/1`, the one SQL
  spelling of a page's public visibility). Takes the two joined bindings.
  """
  defmacro shown_party(u, o) do
    quote do
      not is_nil(unquote(u).id) or
        (not is_nil(unquote(o).id) and organization_public_row(unquote(o)))
    end
  end

  @doc false
  def user_side(%User{id: id}), do: id
  def user_side(%Organization{}), do: nil

  @doc false
  def organization_side(%Organization{id: id}), do: id
  def organization_side(%User{}), do: nil
end
