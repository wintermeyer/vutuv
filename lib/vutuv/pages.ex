defmodule Vutuv.Pages do
  @moduledoc false

  import Phoenix.HTML, only: [raw: 1]

  alias PhoenixHTMLHelpers.Link, as: HTMLLink

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

  def page_list(%{"page" => page}, total) do
    gen_page_links(
      sanitize_page(page),
      total_pages(total)
    )
  end

  def page_list(_, total) do
    page_list(%{"page" => 1}, total)
  end

  defp gen_page_links(page, max) when max > 1 do
    links =
      for(num <- (page - 5)..(page + 5)) do
        cond do
          num > max -> nil
          num < 1 -> nil
          num == page -> page
          true -> page_link(num)
        end
      end
      |> Enum.filter(& &1)
      |> Enum.join(" | ")

    "<div class=\"card__morelink card__morelink-border\">#{pre(page)}#{links}#{post(page, max)}</div>"
    |> raw()
  end

  defp gen_page_links(_, _), do: ""

  defp pre(page) when page - 5 > 1 do
    "... | "
  end

  defp pre(_), do: ""

  defp post(page, max) when page + 5 < max do
    " | ..."
  end

  defp post(_, _), do: ""

  defp page_link(page) do
    HTMLLink.link("#{page}", to: "?page=#{page}")
    |> Phoenix.HTML.safe_to_string()
  end

  defp sanitize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp sanitize_page(page), do: max(page, 1)
end
