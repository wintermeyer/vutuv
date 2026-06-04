defmodule VutuvWeb.Admin.TagController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)

  plug(VutuvWeb.Plug.ResolveSlug,
    slug: "slug",
    model: Vutuv.Tags.Tag,
    assign: :tag,
    field: :slug
  )

  alias Vutuv.Tags.Tag
  alias VutuvWeb.ControllerHelpers

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

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Tag created successfully."),
      redirect_to: ~p"/admin/tags",
      render: "new.html"
    )
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

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Tag updated successfully."),
      redirect_to: &~p"/admin/tags/#{&1}",
      render: "edit.html",
      assigns: [tag: tag]
    )
  end

  def delete(conn, _params) do
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(conn.assigns[:tag])

    conn
    |> put_flash(:info, gettext("Tag deleted successfully."))
    |> redirect(to: ~p"/admin/tags")
  end
end
