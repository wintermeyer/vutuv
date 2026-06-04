defmodule Vutuv.Pages do
  @moduledoc """
  Offset pagination math for browse-style pages (followers, tags, users):
  `paginate/3` bounds an Ecto query from the `?page` param, and
  `effective_page/2` / `total_pages/1` feed the `VutuvWeb.UI.pager/1`
  component that renders the numbered page links. Feed-style LiveView pages
  use cursor pagination instead (see `Vutuv.Activity.notifications_page/2`).
  """

  require Ecto.Query

  @max_page_items Application.compile_env!(:vutuv, [VutuvWeb.Endpoint, :max_page_items])

  def paginate(query, %{"page" => page}, total) do
    query
    |> Ecto.Query.limit(^@max_page_items)
    |> Ecto.Query.offset(^offset(total, @max_page_items, sanitize_page(page)))
  end

  def paginate(query, _, total) do
    paginate(query, %{"page" => 1}, total)
  end

  defp offset(total, limit, page) when (page - 1) * limit < total do
    (page - 1) * limit
  end

  defp offset(_, _, _), do: 0

  def total_pages(total) when total <= 0, do: 1

  def total_pages(total) do
    div(total - 1, @max_page_items) + 1
  end

  @doc """
  The page whose rows `paginate/3` actually returns for these params: the
  sanitized `?page`, except that an out-of-range page falls back to 1 (same
  fallback as `offset/3`), so the pager highlights what is really shown.
  """
  def effective_page(params, total) do
    page = params |> Map.get("page", 1) |> sanitize_page()
    if (page - 1) * @max_page_items < total, do: page, else: 1
  end

  defp sanitize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp sanitize_page(page), do: max(page, 1)
end
