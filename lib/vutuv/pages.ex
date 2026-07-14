defmodule Vutuv.Pages do
  @moduledoc """
  Offset pagination math for browse-style pages (followers, tags, users):
  `paginate/4` bounds an Ecto query from the `?page` param, and
  `effective_page/3` / `total_pages/2` feed the `VutuvWeb.UI.pager/1`
  component that renders the numbered page links. The page size defaults to
  the site-wide `max_page_items/0`; pages that want a denser list (the tag
  endorsers table) pass a smaller `per_page` to all three plus the pager.
  Feed-style LiveView pages use cursor pagination instead (see
  `Vutuv.FeedPage`).
  """

  require Ecto.Query

  @max_page_items Application.compile_env!(:vutuv, [VutuvWeb.Endpoint, :max_page_items])

  @doc "The site-wide default page size; the `per_page` default for every function here."
  def max_page_items, do: @max_page_items

  @doc """
  Bounds `query` to one page of rows. `per_page` defaults to the site-wide
  `max_page_items/0`; pass a smaller value for a denser page. It must match the
  `per_page` handed to `total_pages/2` / `effective_page/3` / the `<.pager>`,
  so the page count matches the rows returned.
  """
  def paginate(query, params, total, per_page \\ @max_page_items)

  def paginate(query, %{"page" => page}, total, per_page) do
    query
    |> Ecto.Query.limit(^per_page)
    |> Ecto.Query.offset(^offset(total, per_page, sanitize_page(page)))
  end

  def paginate(query, _params, total, per_page) do
    paginate(query, %{"page" => 1}, total, per_page)
  end

  defp offset(total, limit, page) when (page - 1) * limit < total do
    (page - 1) * limit
  end

  defp offset(_, _, _), do: 0

  def total_pages(total, per_page \\ @max_page_items)
  def total_pages(total, _per_page) when total <= 0, do: 1

  def total_pages(total, per_page) do
    div(total - 1, per_page) + 1
  end

  @doc "Parses the `?page` param (any map with a `\"page\"` key) to an integer >= 1, defaulting to 1."
  def page_param(params) do
    case Integer.parse(to_string(params["page"])) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  @doc """
  The page whose rows `paginate/4` actually returns for these params: the
  sanitized `?page`, except that an out-of-range page falls back to 1 (same
  fallback as `offset/3`), so the pager highlights what is really shown.
  """
  def effective_page(params, total, per_page \\ @max_page_items) do
    page = params |> Map.get("page", 1) |> sanitize_page()
    if (page - 1) * per_page < total, do: page, else: 1
  end

  defp sanitize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp sanitize_page(page), do: max(page, 1)
end
