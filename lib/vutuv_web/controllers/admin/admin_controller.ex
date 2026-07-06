defmodule VutuvWeb.Admin.AdminController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Geo
  alias Vutuv.Tags.Tag

  def index(conn, _params) do
    # The client IP as the app sees it, plus whether it is only the loopback
    # proxy hop. A live check that nginx forwards X-Forwarded-For so the per-IP
    # rate limiter and the security email work (issues #799, #837).
    client_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    # The full member browser lives at /admin/users; the dashboard just links to
    # it and surfaces the one actionable slice — the identity-verification queue.
    render(conn, "index.html",
      client_ip: client_ip,
      proxy_hop?: Geo.private_or_loopback?(conn.remote_ip),
      members_count: Repo.aggregate(User, :count),
      moderation_count: Vutuv.Moderation.open_queue_count(),
      ads_enabled: Vutuv.Ads.enabled?(),
      pending_ads_count: if(Vutuv.Ads.enabled?(), do: Vutuv.Ads.pending_ads_count(), else: 0),
      api_apps_count: Repo.aggregate(Vutuv.ApiAuth.App, :count),
      tags_count: Repo.aggregate(Tag, :count),
      honor_tags_count: Vutuv.Tags.honor_tags_count(),
      frozen_accounts_count: Vutuv.Deliverability.frozen_count(),
      fediverse_enabled: Vutuv.Fediverse.enabled?(),
      # Only the four COUNTs when the card will actually show them; an
      # air-gapped install (FEDIVERSE_ENABLED=false) hides the card, mirroring
      # the ads line above.
      fediverse_stats: if(Vutuv.Fediverse.enabled?(), do: Vutuv.Fediverse.stats())
    )
  end
end
