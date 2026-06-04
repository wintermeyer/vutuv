defmodule VutuvWeb.Api.PhoneNumberController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:phone_numbers])

    render(conn, "index.json", phone_numbers: user.phone_numbers)
  end

  # def create(conn, %{"phone_number" => phone_number_params}) do
  #   changeset = PhoneNumber.changeset(%PhoneNumber{}, phone_number_params)

  #   case Repo.insert(changeset) do
  #     {:ok, phone_number} ->
  #       conn
  #       |> put_status(:created)
  #       |> put_resp_header("location", api_user_phone_number_path(conn, :show, phone_number))
  #       |> render("show.json", phone_number: phone_number)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  def show(conn, %{"id" => id}) do
    phone_number = Repo.get!(assoc(conn.assigns[:user], :phone_numbers), id)
    render(conn, "show.json", phone_number: phone_number)
  end

  # def update(conn, %{"id" => id, "phone_number" => phone_number_params}) do
  #   phone_number = Repo.get!(PhoneNumber, id)
  #   changeset = PhoneNumber.changeset(phone_number, phone_number_params)

  #   case Repo.update(changeset) do
  #     {:ok, phone_number} ->
  #       render(conn, "show.json", phone_number: phone_number)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def delete(conn, %{"id" => id}) do
  #   phone_number = Repo.get!(PhoneNumber, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(phone_number)

  #   send_resp(conn, :no_content, "")
  # end
end
