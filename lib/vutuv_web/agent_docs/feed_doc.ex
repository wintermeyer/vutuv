defmodule VutuvWeb.AgentDocs.FeedDoc do
  @moduledoc """
  The signed-in member's newsfeed (`/feed`) as a data map for the agent
  formats — the personalized timeline `VutuvWeb.PostLive.Feed` renders, but
  as Markdown / text / JSON / XML (no vCard; a feed has no contact card).

  Unlike every other `VutuvWeb.AgentDocs` builder this one is **not** the
  anonymous public view: the feed is per-viewer and login-only. So the doc is
  always `noindex: true` + `noai: true` (a private timeline is never crawled
  or trained on), and `VutuvWeb.NewsfeedController` sends it with a private,
  no-store cache so a shared cache can never hand one member's feed to
  another. There is no anonymous HTML to drift against, so it is covered by
  its own controller test rather than the agent-docs drift test.

  One page is rendered (the same cursor pagination the LiveView uses): `more`
  flags that older posts remain, and `next_cursor` is the opaque token to pass
  back as `?cursor=` for the next page.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.PostDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.UserHelpers

  @doc """
  Builds the feed doc for `viewer` from a `Vutuv.Posts.feed_page/2` result
  (`%{entries:, more?:, next_cursor:}`). Each entry renders through the shared
  `PostDoc.timeline_entry/1`, so a feed post reads exactly like an archive post.

  `next_cursor` is the in-memory keyset cursor signed into the same opaque,
  tamper-proof token the API hands out (`ApiV2.encode_cursor/1`), so it is safe
  to put in a `?cursor=` URL and `VutuvWeb.FeedController` decodes it back.
  """
  def build(viewer, page) do
    name = UserHelpers.full_name(viewer)

    AgentDocs.doc_meta("feed", "/feed", noindex: true, noai: true)
    |> Map.merge(%{
      title: gettext("Feed of %{name}", name: name),
      description: gettext("The vutuv newsfeed of %{name}", name: name),
      viewer: AgentDocs.person_ref(viewer),
      more: page.more?,
      next_cursor: ApiV2.encode_cursor(page.more? && page.next_cursor),
      posts: Enum.map(page.entries, &PostDoc.timeline_entry/1)
    })
  end
end
