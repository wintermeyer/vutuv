defmodule VutuvWeb.Admin.ExonymController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.Exonym
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    exonyms_count = Repo.one(from(e in Exonym, select: count(e.id)))

    exonyms =
      from(e in Exonym, order_by: e.value, preload: [:locale, :exonym_locale])
      |> Vutuv.Pages.paginate(conn.params, exonyms_count)
      |> Repo.all()

    render(conn, "index.html", exonyms: exonyms, exonyms_count: exonyms_count)
  end

  def new(conn, _params) do
    changeset = Exonym.changeset(%Exonym{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"exonym" => exonym_params}) do
    changeset = Exonym.changeset(%Exonym{}, exonym_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Exonym created successfully."),
      redirect_to: ~p"/admin/exonyms",
      render: "new.html"
    )
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

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Exonym updated successfully."),
      redirect_to: &~p"/admin/exonyms/#{&1}",
      render: "edit.html",
      assigns: [exonym: exonym]
    )
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
