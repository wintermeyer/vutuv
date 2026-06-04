defmodule VutuvWeb.Api.EmailController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    emails =
      Repo.all(from(e in assoc(conn.assigns[:user], :emails), where: e.public?))

    render(conn, "index.json", emails: emails)
  end

  # def create(conn, %{"email" => email_params}) do
  #   changeset = Email.changeset(%Email{}, email_params)

  #   case Repo.insert(changeset) do
  #     {:ok, email} ->
  #       conn
  #       |> put_status(:created)
  #       |> put_resp_header("location", api_user_email_path(conn, :show, email))
  #       |> render("show.json", email: email)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  def show(conn, %{"id" => id}) do
    query =
      from(e in assoc(conn.assigns[:user], :emails), where: e.id == ^id and e.public?)

    case Repo.one(query) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: VutuvWeb.ErrorJSON)
        |> render("error.json")
        |> halt

      email ->
        render(conn, "show.json", email: email)
    end
  end

  # def update(conn, %{"id" => id, "email" => email_params}) do
  #   email = Repo.get!(Email, id)
  #   changeset = Email.changeset(email, email_params)

  #   case Repo.update(changeset) do
  #     {:ok, email} ->
  #       render(conn, "show.json", email: email)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def delete(conn, %{"id" => id}) do
  #   email = Repo.get!(Email, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(email)

  #   send_resp(conn, :no_content, "")
  # end
end
