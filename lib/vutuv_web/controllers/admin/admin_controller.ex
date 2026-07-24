defmodule VutuvWeb.Admin.AdminController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Geo
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Tags.Tag

  def index(conn, _params) do
    # The client IP as the app sees it, plus whether it is only the loopback
    # proxy hop. A live check that nginx forwards X-Forwarded-For so the per-IP
    # rate limiter and the security email work (issues #799, #837).
    client_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    jobs_counts = Vutuv.Jobs.admin_overview_counts()

    # The full member browser lives at /admin/users; the dashboard just links to
    # it and surfaces the one actionable slice — the identity-verification queue.
    render(conn, "index.html",
      client_ip: client_ip,
      proxy_hop?: Geo.private_or_loopback?(conn.remote_ip),
      members_count: Repo.aggregate(User, :count),
      moderation_count: Vutuv.Moderation.open_queue_count(),
      image_moderation_enabled: ImageScans.enabled?(),
      image_scan_counts: ImageScans.counts(),
      ads_enabled: Vutuv.Ads.enabled?(),
      pending_ads_count: if(Vutuv.Ads.enabled?(), do: Vutuv.Ads.pending_ads_count(), else: 0),
      api_apps_count: Repo.aggregate(Vutuv.ApiAuth.App, :count),
      tags_count: Repo.aggregate(Tag, :count),
      honor_tags_count: Vutuv.Tags.honor_tags_count(),
      organizations_count: Vutuv.Organizations.admin_overview_counts().active,
      flagged_aliases_count: Vutuv.Organizations.flagged_aliases_count(),
      jobs_published_count: jobs_counts.published,
      jobs_open_cases_count: jobs_counts.open_cases,
      pref_overrides_count: map_size(Vutuv.Prefs.list_default_rows()),
      frozen_accounts_count: Vutuv.Deliverability.frozen_count(),
      moderation_frozen_count: Vutuv.Moderation.frozen_accounts_count(),
      fediverse_enabled: Fediverse.enabled?(),
      # Only the COUNTs when the card will actually show them; an air-gapped
      # install (FEDIVERSE_ENABLED=false) hides the card, mirroring the ads line
      # above.
      fediverse_stats: if(Fediverse.enabled?(), do: Fediverse.stats()),
      fediverse_top_host: if(Fediverse.enabled?(), do: top_inbound_host())
    )
  end

  # The one server sending us the most, for the dashboard card's inbound line
  # (issue #1067); nil while nothing has arrived.
  defp top_inbound_host do
    case Fediverse.inbound_hosts(1) do
      [%{host: host} | _] -> host
      [] -> nil
    end
  end
end
