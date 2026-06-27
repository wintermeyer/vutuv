defmodule VutuvWeb.Admin.AdminController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Tags.Tag

  def index(conn, _params) do
    # The full member browser lives at /admin/users; the dashboard just links to
    # it and surfaces the one actionable slice — the identity-verification queue.
    render(conn, "index.html",
      members_count: Repo.aggregate(User, :count),
      unverified_count:
        Repo.aggregate(from(u in User, where: u.identity_verified? != true), :count),
      moderation_count: Vutuv.Moderation.open_queue_count(),
      ads_enabled: Vutuv.Ads.enabled?(),
      pending_ads_count: if(Vutuv.Ads.enabled?(), do: Vutuv.Ads.pending_ads_count(), else: 0),
      api_apps_count: Repo.aggregate(Vutuv.ApiAuth.App, :count),
      tags_count: Repo.aggregate(Tag, :count),
      frozen_accounts_count: Vutuv.Deliverability.frozen_count()
    )
  end
end
