defmodule VutuvWeb.TagController do
  use VutuvWeb, :controller

  alias Vutuv.Tags.Tag

  plug(:resolve_tag)

  def index(conn, _params) do
    tags_count = Repo.one(from(t in Tag, select: count(t.id)))

    tags =
      from(t in Tag)
      |> Vutuv.Pages.paginate(conn.params, tags_count)
      |> Repo.all()

    render(conn, "index.html", tags: tags, tags_count: tags_count)
  end

  def show(conn, _params) do
    render(conn, "show.html", tag: conn.assigns[:tag])
  end

  defp resolve_tag(%{params: %{"slug" => slug}} = conn, _opts) do
    Repo.one(from(t in Vutuv.Tags.Tag, where: t.slug == ^slug))
    |> case do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")
        |> halt

      tag ->
        assign(conn, :tag, tag)
    end
  end

  defp resolve_tag(conn, _opts), do: conn
end
