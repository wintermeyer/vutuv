defmodule Vutuv.Accounts.ReservedSlugs do
  @moduledoc """
  Path words a user slug must never claim.

  Profiles live at the URL root (`/:slug`), so a slug equal to a route
  prefix or a static asset directory would either shadow that route or be
  shadowed by it forever. Keep this list in sync with the first path
  segments in `VutuvWeb.Router` and the `Plug.Static` mounts in
  `VutuvWeb.Endpoint`.

  Handles allow underscores (`^[a-z0-9_]+$`, 3-15 characters), so route
  words *with* underscores must be listed too — only those longer than 15
  characters (new_registration, account_deletion) are ruled out by the
  length limit alone.
  """

  # Router prefixes (current and legacy), endpoint/static paths, and a few
  # conventional names kept free for future use.
  @reserved ~w(
    about admin ads api assets avatars blocks blog bookmarks community connections contact
    covers css datenschutzerklaerung dev edit emails favicon.ico feed follow_back
    follows fonts groups help images impressum jobs js legal likes listings live
    llms.txt login logout mail memberships messages moderation new news
    notifications phoenix post_images posts press privacy reports robots.txt
    screenshots search search_queries security.txt sent_emails sessions settings
    sitemap.xml socket status support tags team terms tidewave unsubscribe
    users webhooks www
  )

  def list, do: @reserved
end
