defmodule VutuvWeb.Admin.TagController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.ResolveSlug,
    slug: "slug",
    model: Vutuv.Tags.Tag,
    assign: :tag,
    field: :slug
  )

  alias Vutuv.Pages
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias VutuvWeb.ControllerHelpers

  def index(conn, params) do
    # Guard against a crafted `?q[x]=1` (a map/list) that `to_string/1` would 500 on.
    query =
      case Map.get(params, "q") do
        q when is_binary(q) -> String.trim(q)
        _ -> ""
      end

    # The catalog is the one screen that shows alternative names too (issue
    # #1338), marked and linked to the topic they belong to — an admin looking
    # for a tag by a name that was absorbed must still find it here.
    base = Tags.admin_search(query, merged: :include)
    tags_count = Repo.aggregate(base, :count)

    tags =
      from(t in base, order_by: t.slug, preload: [:merged_into])
      |> Pages.paginate(params, tags_count)
      |> Repo.all()

    render(conn, "index.html",
      tags: tags,
      tags_count: tags_count,
      query: query,
      pager_query: (query != "" && %{"q" => query}) || %{}
    )
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
    tag = conn.assigns[:tag]
    render(conn, "show.html", tag: tag, holders: Tags.tag_holders(tag))
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
