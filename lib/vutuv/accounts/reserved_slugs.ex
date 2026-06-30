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

  A second group reserves a handful of **personal / brand handles** that are
  not routes but should never be claimed by an arbitrary member.
  """

  # Router prefixes (current and legacy), endpoint/static paths, and a few
  # conventional names kept free for future use.
  @route_slugs ~w(
    about access_tokens admin ads api assets avatars blocks blog bookmarks community
    connected_apps connections contact covers css datenschutzerklaerung dev developers
    edit emails favicon.ico feed follow_back
    follows fonts groups health help images impressum jobs js legal likes listings live
    llms.txt login logout mail maps memberships messages moderation new news
    notifications oauth phoenix post_images posts press privacy reports robots.txt
    screenshots search search_queries security.txt sent_emails sessions settings
    sitemap.xml sitemaps socket status support tags team terms tidewave unsubscribe
    user_bookmarks user_likes users webhooks www
  )

  # Personal / brand handles held back from public registration. These are not
  # routes. `sw`, `aw` and `jw` sit below the 3-character handle minimum, so for
  # usernames they are belt-and-suspenders; reserving them still steers
  # auto-generated handles and slug resolution away from these names.
  @handle_slugs ~w(stefan aurelius juna sw aw jw)

  @reserved @route_slugs ++ @handle_slugs

  def list, do: @reserved
end
