defmodule VutuvWeb.Admin.AdminController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User

  def index(conn, _params) do
    # The verification queue grows without bound, so it is paginated;
    # newest registrations first (id as deterministic tie-break).
    total = Repo.aggregate(from(u in User, where: u.verified != true), :count)

    users =
      from(u in User, where: u.verified != true, order_by: [desc: u.inserted_at, desc: u.id])
      |> Vutuv.Pages.paginate(conn.params, total)
      |> Repo.all()

    render(conn, "index.html", users: users, users_count: total)
  end
end
