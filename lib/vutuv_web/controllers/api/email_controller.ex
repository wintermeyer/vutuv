defmodule VutuvWeb.Api.EmailController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    emails =
      Repo.all(from(e in assoc(conn.assigns[:user], :emails), where: e.public?))

    render(conn, "index.json", emails: emails)
  end

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
end
