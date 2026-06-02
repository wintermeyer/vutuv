defmodule VutuvWeb.Admin.AdminController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)

  alias Vutuv.Accounts.User

  def index(conn, _params) do
    users = Repo.all(from(u in User, where: u.verified != true))
    render(conn, "index.html", users: users)
  end
end
