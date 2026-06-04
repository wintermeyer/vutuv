defmodule VutuvWeb.Plug.ResolveOwnedSlug do
  @moduledoc """
  Resolve a member resource scoped to a parent already in `conn.assigns`, then
  assign it. The lookup is owner-scoped through the parent association, so a
  request can only reach resources that hang off the parent it owns; an unknown
  (or foreign) slug renders a clean 404 and halts. When the slug param is absent
  (a collection action such as `:index`/`:new`), the conn passes through
  unchanged so the action runs without the assign.

  This is the association-scoped sibling of `VutuvWeb.Plug.ResolveSlug` (which
  resolves an unscoped, globally unique model by slug).

  Options:

    * `:parent` — assign holding the loaded parent (e.g. `:user`, `:job_posting`)
    * `:assoc` — the parent's association to scope through (e.g. `:work_experiences`)
    * `:slug_param` — the request param carrying the slug (e.g. `"id"`)
    * `:field` — the column the slug is matched against (e.g. `:slug`)
    * `:assign` — the assign the resolved value is stored under
    * `:join` — optional association to join before matching `:field` on it
      (e.g. `:tag` when the slug lives on the joined tag, not the member row)
    * `:select` — optional field to select instead of the whole struct
      (e.g. `:id` to assign just the id)
  """

  import Plug.Conn
  import Ecto.Query
  alias Vutuv.Repo

  def init(opts) do
    %{
      parent: Keyword.fetch!(opts, :parent),
      assoc: Keyword.fetch!(opts, :assoc),
      slug_param: Keyword.fetch!(opts, :slug_param),
      field: Keyword.fetch!(opts, :field),
      assign: Keyword.fetch!(opts, :assign),
      join: Keyword.get(opts, :join),
      select: Keyword.get(opts, :select)
    }
  end

  def call(%{params: %{} = params} = conn, %{slug_param: slug_param} = opts) do
    case params do
      %{^slug_param => slug} ->
        case Repo.one(query(conn.assigns[opts.parent], slug, opts)) do
          nil -> invalid_slug(conn)
          resolved -> assign(conn, opts.assign, resolved)
        end

      _ ->
        conn
    end
  end

  defp query(parent, slug, %{join: nil, assoc: assoc, field: field} = opts) do
    from(m in Ecto.assoc(parent, assoc), where: field(m, ^field) == ^slug)
    |> maybe_select(opts.select)
  end

  defp query(parent, slug, %{join: join, assoc: assoc, field: field} = opts) do
    from(m in Ecto.assoc(parent, assoc),
      join: j in assoc(m, ^join),
      where: field(j, ^field) == ^slug
    )
    |> maybe_select(opts.select)
  end

  defp maybe_select(query, nil), do: query
  defp maybe_select(query, field), do: from(m in query, select: field(m, ^field))

  defp invalid_slug(conn) do
    VutuvWeb.ControllerHelpers.render_error(conn, 404)
  end
end
