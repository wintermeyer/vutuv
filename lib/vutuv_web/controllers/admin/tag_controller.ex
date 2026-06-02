defmodule VutuvWeb.Admin.TagController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)
  plug(:resolve_tag)

  alias Vutuv.Tags.Tag

  def index(conn, _params) do
    tags = Repo.all(Tag)
    render(conn, "index.html", tags: tags)
  end

  def new(conn, _params) do
    changeset = Tag.changeset(%Tag{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"tag" => tag_params}) do
    changeset = Tag.changeset(%Tag{}, tag_params)

    case Repo.insert(changeset) do
      {:ok, _tag} ->
        conn
        |> put_flash(:info, gettext("Tag created successfully."))
        |> redirect(to: ~p"/admin/tags")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, _params) do
    render(conn, "show.html", tag: conn.assigns[:tag])
  end

  def edit(conn, _params) do
    tag = conn.assigns[:tag]
    changeset = Tag.edit_changeset(tag)
    render(conn, "edit.html", tag: tag, changeset: changeset)
  end

  def update(conn, %{"tag" => tag_params}) do
    tag =
      conn.assigns[:tag]

    changeset = Tag.edit_changeset(tag, tag_params)

    case Repo.update(changeset) do
      {:ok, tag} ->
        conn
        |> put_flash(:info, gettext("Tag updated successfully."))
        |> redirect(to: ~p"/admin/tags/#{tag}")

      {:error, changeset} ->
        render(conn, "edit.html", tag: tag, changeset: changeset)
    end
  end

  def delete(conn, _params) do
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(conn.assigns[:tag])

    conn
    |> put_flash(:info, gettext("Tag deleted successfully."))
    |> redirect(to: ~p"/admin/tags")
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
