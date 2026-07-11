defmodule Vutuv.Accounts.ReservedSlugs do
  @moduledoc """
  Path words a user slug must never claim.

  Profiles live at the URL root (`/:slug`), so a slug equal to a route
  prefix or a static asset directory would either shadow that route or be
  shadowed by it forever. Keep this list in sync with the first path
  segments in `VutuvWeb.Router` and the `Plug.Static` mounts in
  `VutuvWeb.Endpoint`.

  Handles allow underscores (`^[a-z0-9_]+$`) and run up to
  `Vutuv.Handles.max_length/0` characters, so every route word within those
  bounds must be listed too — including the longer underscore/compound words
  (account_deletion, new_registration, nutzungsbedingungen). Widening the
  handle ceiling can expose more of them; `reserved_slugs_router_test.exs`
  fails the build on the next such drift.

  A second group reserves a handful of **personal / brand handles** that are
  not routes but should never be claimed by an arbitrary member.
  """

  # Router prefixes (current and legacy), endpoint/static paths, and a few
  # conventional names kept free for future use. New site pages (listings,
  # directories, tools) go under the already-reserved /system/ prefix instead
  # of claiming another root word — see CLAUDE.md; the member directory
  # (/system/members) set the pattern, freeing "members" as a handle again.
  @route_slugs ~w(
    about access_tokens account_deletion admin ads api assets avatars benutzername blocks blog bookmarks
    organizations organization_images community connected_apps connections contact covers css datenschutzerklaerung dev developers
    edit emails favicon.ico feed follow_back
    follows fonts groups health help images impressum jobs js legal likes listings live
    llms.txt login logout mail maps memberships messages moderation new new_registration news
    notifications nutzungsbedingungen oauth phoenix post_images job_posting_images posts press privacy reports robots.txt
    screenshots search search_queries security.txt sent_emails sessions settings
    sitemap.xml sitemaps socket status support system tags team terms tidewave unsubscribe
    user_bookmarks user_likes username users webhooks www
  )

  # Personal / brand handles held back from public registration. These are not
  # routes. `sw`, `aw` and `jw` sit below the `Vutuv.Handles.min_length/0`
  # handle minimum, so for usernames they are belt-and-suspenders; reserving
  # them still steers auto-generated handles and slug resolution away from these
  # names.
  @handle_slugs ~w(stefan aurelius juna sw aw jw)

  @reserved @route_slugs ++ @handle_slugs

  def list, do: @reserved
end
