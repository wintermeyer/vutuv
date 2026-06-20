defmodule VutuvWeb.Admin.AdminController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User

  def index(conn, _params) do
    # The verification queue grows without bound, so it is paginated;
    # newest registrations first (id as deterministic tie-break).
    total = Repo.aggregate(from(u in User, where: u.identity_verified? != true), :count)

    users =
      from(u in User,
        where: u.identity_verified? != true,
        order_by: [desc: u.inserted_at, desc: u.id]
      )
      |> Vutuv.Pages.paginate(conn.params, total)
      |> Repo.all()

    render(conn, "index.html",
      users: users,
      users_count: total,
      moderation_count: Vutuv.Moderation.open_queue_count(),
      ads_enabled: Vutuv.Ads.enabled?(),
      pending_ads_count: if(Vutuv.Ads.enabled?(), do: Vutuv.Ads.pending_ads_count(), else: 0),
      api_apps_count: Repo.aggregate(Vutuv.ApiAuth.App, :count),
      frozen_accounts_count: Vutuv.Deliverability.frozen_count()
    )
  end
end
