defmodule VutuvWeb.Api.PhoneNumberController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:phone_numbers])

    render(conn, "index.json", phone_numbers: user.phone_numbers)
  end

  def show(conn, %{"id" => id}) do
    phone_number = Repo.get!(assoc(conn.assigns[:user], :phone_numbers), id)
    render(conn, "show.json", phone_number: phone_number)
  end
end
