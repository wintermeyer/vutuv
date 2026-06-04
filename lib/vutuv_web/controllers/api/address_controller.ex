defmodule VutuvWeb.Api.AddressController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:addresses])

    render(conn, "index.json", addresses: user.addresses)
  end

  def show(conn, %{"id" => id}) do
    address = Repo.get!(assoc(conn.assigns[:user], :addresses), id)
    render(conn, "show.json", address: address)
  end
end
