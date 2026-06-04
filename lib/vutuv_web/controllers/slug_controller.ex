defmodule VutuvWeb.SlugController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.All404)

  alias Vutuv.Accounts.Slug
  alias VutuvWeb.ControllerHelpers
  import Ecto, only: [assoc: 2, build_assoc: 2]

  def index(conn, _params) do
    slugs = Repo.all(assoc(conn.assigns[:user], :slugs))
    render(conn, "index.html", slugs: slugs)
  end

  def new(conn, _params) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:slugs)
      |> Slug.changeset()

    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"slug" => params}) do
    case Repo.transaction(new_slug(conn.assigns[:user], params)) do
      {:ok, %{user: user, slug: _slug}} ->
        conn
        |> put_flash(:info, gettext("Slug updated successfully."))
        |> redirect(to: ~p"/users/#{user}")

      {:error, _failure, changeset, _} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    slug = ControllerHelpers.get_owned!(conn, :slugs, id)
    render(conn, "show.html", slug: slug)
  end

  def update(conn, %{"id" => id}) do
    slug = ControllerHelpers.get_owned!(conn, :slugs, id)

    changeset =
      Ecto.Changeset.cast(conn.assigns[:current_user], %{active_slug: slug.value}, [:active_slug])

    case Repo.update(changeset) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("Slug activated successfully"))
        |> redirect(to: ~p"/users/#{user}/slugs")

      {:error, _changeset} ->
        redirect(conn, to: ~p"/users/#{conn.assigns[:current_user]}/slugs")
    end
  end

  def new_slug(user, params) do
    slug_changeset =
      user
      |> build_assoc(:slugs)
      |> Slug.changeset(params)

    user_changeset =
      Ecto.Changeset.cast(user, %{"active_slug" => slug_changeset.changes.value}, [:active_slug])

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:slug, slug_changeset)
    |> Ecto.Multi.update(:user, user_changeset)
  end
end
