defmodule VutuvWeb.UserTagController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :user_tags,
    join: :tag,
    slug_param: "id",
    field: :slug,
    assign: :user_tag
  )

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "tag_param" when action in [:create])

  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(user_tags: :tag)

    render(conn, "index.html", user: user, user_tags: user.user_tags)
  end

  def new(conn, _params) do
    changeset = UserTag.changeset(%UserTag{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"tag_param" => tag_param}) do
    conn.assigns[:current_user]
    |> Ecto.build_assoc(:user_tags, %{})
    |> UserTag.changeset()
    |> Tag.create_or_link_tag(tag_param)
    |> Repo.insert()
    |> case do
      {:ok, _user_tag} ->
        conn
        |> put_flash(:info, gettext("User tag created successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/tags")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => _id}) do
    user_tag =
      conn.assigns[:user_tag]
      |> Repo.preload([:tag, :endorsements])

    render(conn, "show.html", user_tag: user_tag)
  end

  def delete(conn, %{"id" => _id}) do
    user_tag = conn.assigns[:user_tag]

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(user_tag)

    conn
    |> put_flash(:info, gettext("User tag deleted successfully."))
    |> redirect(to: ~p"/users/#{conn.assigns[:user]}/tags")
  end
end
