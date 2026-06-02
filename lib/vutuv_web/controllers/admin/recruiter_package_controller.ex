defmodule VutuvWeb.Admin.RecruiterPackageController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)

  alias Vutuv.Recruiting.RecruiterPackage

  def index(conn, _params) do
    recruiter_packages = Repo.all(RecruiterPackage)
    render(conn, "index.html", recruiter_packages: recruiter_packages)
  end

  def new(conn, _params) do
    {{year, month, day}, {_hour, _min, _sec}} = :erlang.localtime()

    {end_year, end_month, end_day} =
      :calendar.gregorian_days_to_date(:calendar.date_to_gregorian_days({year, month, day}) + 365)

    changeset =
      RecruiterPackage.changeset(%RecruiterPackage{
        offer_begins: Date.new!(year, month, day),
        offer_ends: Date.new!(end_year, end_month, end_day)
      })

    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"recruiter_package" => recruiter_package_params}) do
    changeset = RecruiterPackage.changeset(%RecruiterPackage{}, recruiter_package_params)

    case Repo.insert(changeset) do
      {:ok, _recruiter_package} ->
        conn
        |> put_flash(:info, gettext("Recruiter package created successfully."))
        |> redirect(to: ~p"/admin/recruiter_packages")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"package_slug" => id}) do
    recruiter_package = Repo.get!(RecruiterPackage, id)
    render(conn, "show.html", recruiter_package: recruiter_package)
  end

  def edit(conn, %{"package_slug" => id}) do
    recruiter_package = Repo.get!(RecruiterPackage, id)
    changeset = RecruiterPackage.changeset(recruiter_package)
    render(conn, "edit.html", recruiter_package: recruiter_package, changeset: changeset)
  end

  def update(conn, %{"package_slug" => id, "recruiter_package" => recruiter_package_params}) do
    recruiter_package = Repo.get!(RecruiterPackage, id)
    changeset = RecruiterPackage.changeset(recruiter_package, recruiter_package_params)

    case Repo.update(changeset) do
      {:ok, recruiter_package} ->
        conn
        |> put_flash(:info, gettext("Recruiter package updated successfully."))
        |> redirect(to: ~p"/admin/recruiter_packages/#{recruiter_package}")

      {:error, changeset} ->
        render(conn, "edit.html", recruiter_package: recruiter_package, changeset: changeset)
    end
  end

  def delete(conn, %{"package_slug" => id}) do
    recruiter_package = Repo.get!(RecruiterPackage, id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(recruiter_package)

    conn
    |> put_flash(:info, gettext("Recruiter package deleted successfully."))
    |> redirect(to: ~p"/admin/recruiter_packages")
  end
end
