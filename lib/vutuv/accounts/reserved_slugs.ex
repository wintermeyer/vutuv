defmodule Vutuv.Accounts.ReservedSlugs do
  @moduledoc """
  Path words a user slug must never claim.

  Profiles live at the URL root (`/:slug`), so a slug equal to a route
  prefix or a static asset directory would either shadow that route or be
  shadowed by it forever. Keep this list in sync with the first path
  segments in `VutuvWeb.Router` and the `Plug.Static` mounts in
  `VutuvWeb.Endpoint`.

  Words containing an underscore (new_registration, search_queries, ...)
  are not listed: the slug format `^[a-z][a-z0-9-.]*$` already rules them
  out.
  """

  # Router prefixes (current and legacy), endpoint/static paths, and a few
  # conventional names kept free for future use.
  @reserved ~w(
    about admin api assets avatars blog connections contact covers css
    datenschutzerklaerung dev edit emails favicon.ico feed fonts groups help
    images impressum jobs js legal listings live login logout mail
    memberships messages new news notifications phoenix posts press privacy
    robots.txt screenshots search security.txt sessions settings
    sitemap.xml socket status support tags team terms tidewave users www
  )

  def list, do: @reserved

  def reserved?(value), do: value in @reserved
end
