defmodule VutuvWeb.Api.AddressController do
  use VutuvWeb, :controller
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:addresses])

    render(conn, "index.json", addresses: user.addresses)
  end

  def show(conn, %{"id" => id}) do
    address = ControllerHelpers.get_owned!(conn, :addresses, id)
    render(conn, "show.json", address: address)
  end
end
