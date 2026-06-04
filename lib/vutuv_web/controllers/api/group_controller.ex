defmodule VutuvWeb.Api.GroupController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:groups])

    render(conn, "index.json", groups: user.groups)
  end

  def show(conn, %{"id" => id}) do
    group = Repo.get!(assoc(conn.assigns[:user], :groups), id)
    render(conn, "show.json", group: group)
  end
end
