defmodule VutuvWeb.Admin.ExonymController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)

  alias Vutuv.Accounts.Exonym

  def index(conn, _params) do
    exonyms = Repo.all(from(e in Exonym, preload: [:locale, :exonym_locale]))
    render(conn, "index.html", exonyms: exonyms)
  end

  def new(conn, _params) do
    changeset = Exonym.changeset(%Exonym{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"exonym" => exonym_params}) do
    changeset = Exonym.changeset(%Exonym{}, exonym_params)

    case Repo.insert(changeset) do
      {:ok, _exonym} ->
        conn
        |> put_flash(:info, gettext("Exonym created successfully."))
        |> redirect(to: ~p"/admin/exonyms")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    exonym =
      Repo.get!(Exonym, id)
      |> Repo.preload([:locale, :exonym_locale])

    render(conn, "show.html", exonym: exonym)
  end

  def edit(conn, %{"id" => id}) do
    exonym = Repo.get!(Exonym, id)
    changeset = Exonym.changeset(exonym)
    render(conn, "edit.html", exonym: exonym, changeset: changeset)
  end

  def update(conn, %{"id" => id, "exonym" => exonym_params}) do
    exonym = Repo.get!(Exonym, id)
    changeset = Exonym.changeset(exonym, exonym_params)

    case Repo.update(changeset) do
      {:ok, exonym} ->
        conn
        |> put_flash(:info, gettext("Exonym updated successfully."))
        |> redirect(to: ~p"/admin/exonyms/#{exonym}")

      {:error, changeset} ->
        render(conn, "edit.html", exonym: exonym, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    exonym = Repo.get!(Exonym, id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(exonym)

    conn
    |> put_flash(:info, gettext("Exonym deleted successfully."))
    |> redirect(to: ~p"/admin/exonyms")
  end
end
