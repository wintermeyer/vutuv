defmodule VutuvWeb.TagController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Jobs
  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.Timeline
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.UserHelpers

  # Not the shared `ResolveSlug` plug: an alternative name for a topic keeps its
  # own slug (issue #1338), and that URL must lead to the topic rather than 404
  # or render a second page for it. So the resolution has three answers, not
  # two — see `resolve_tag/2`.
  plug(:resolve_tag)

  def index(conn, _params) do
    listable = Tag.not_merged()
    tags_count = Repo.aggregate(listable, :count)

    tags =
      from(t in listable, order_by: fragment("lower(coalesce(?, ?))", t.name, t.slug))
      |> Pages.paginate(conn.params, tags_count)
      |> Repo.all()

    render(conn, "index.html",
      tags: tags,
      tags_count: tags_count,
      page_title: gettext("Tags")
    )
  end

  # Resolves the `:slug` param: a topic is assigned and rendered; an alternative
  # name **redirects permanently** to the topic it names; anything else is a
  # clean 404. Actions without the param (`:index`) pass through.
  #
  # 301 and not 302, because the absorbed page's ranking signal should pass to
  # the page that survived. The requested agent format rides along on its own:
  # `VutuvWeb.Plug.AgentFormat` re-appends the extension to any in-app redirect,
  # so `/tags/rubyonrails.md` lands on `/tags/ruby_on_rails.md` and never falls
  # back to HTML. The query string is carried here, since the redirect is what
  # loses it otherwise (`?source=fediverse` selects the timeline's half).
  defp resolve_tag(%{params: %{"slug" => slug}} = conn, _opts) do
    case Repo.get_by(Tag, slug: slug) do
      nil ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)

      %Tag{merged_into_id: nil} = tag ->
        assign(conn, :tag, tag)

      %Tag{} = tag_alias ->
        conn
        |> put_status(:moved_permanently)
        |> redirect(to: canonical_path(tag_alias, conn.query_string))
        |> halt()
    end
  end

  defp resolve_tag(conn, _opts), do: conn

  defp canonical_path(tag_alias, query_string) do
    path = ~p"/tags/#{Tag.canonical(tag_alias)}"

    if query_string == "", do: path, else: path <> "?" <> query_string
  end

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs
  # (anonymous view: the description, the most endorsed members and the timeline
  # of posts carrying this tag — not the viewer-dependent "people you may know").
  # Keep show.html and the doc builder in sync (agent_docs_drift_test.exs).
  def show(conn, _params) do
    tag = conn.assigns[:tag]
    current_user = conn.assigns[:current_user]

    # The header follow control (issue #872): whether the viewer already follows
    # this tag, and the public aggregate follower count. The follow state is
    # viewer-specific, so it rides only on the HTML branch (the agent formats are
    # the anonymous public view). The count is a public aggregate shown as social
    # proof; it is UI chrome, not tag content, so it stays out of the agent docs.
    # While speaking for a page the pill shows the **page's** subscription
    # (issue #1336) — that is whose feed the topic would reach, so showing the
    # member's state here would offer to unfollow something the page never
    # followed.
    following_tag? = tag_followed?(conn.assigns[:acting_as], current_user, tag)
    # The public figure is everyone following this topic, wherever their account
    # lives (issue #1330): the local `TagFollow` rows plus the remote actors.
    # Splitting them would ask a reader to add two numbers that mean one thing.
    tag_follower_count =
      Tags.tag_follower_count(tag) + Fediverse.tag_remote_follower_count(tag)

    # A tag page below the search-engine bar (fewer than
    # Tags.min_indexable_members/0 visible members and no public post) is a
    # thin near-duplicate in a search index; thousands of them sat in Search
    # Console as "crawled - currently not indexed". It stays served and
    # linkable, but carries noindex (on every format) so crawlers drop it
    # deliberately; the sitemap advertises only the tags above the bar.
    indexable? = Tags.indexable_tag?(tag)

    conn =
      if indexable?,
        do: conn,
        else: ContentPolicy.put_robots_header(conn, true, false)

    # The HTML page subtracts what the signed-in viewer may not see from the
    # jobs (#939 exclusions / blocks); the agent formats stay the anonymous
    # public view, so each branch loads its own list (only one runs).
    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          tag: tag,
          current_user: current_user,
          following_tag?: following_tag?,
          tag_follower_count: tag_follower_count,
          # nil unless this installation federates, in which case the card shows
          # the topic's address and the "follow from your own server" form.
          fediverse_handle: tag_fediverse_handle(tag),
          open_positions: Jobs.list_tag_postings(tag, conn.assigns[:current_user]),
          # The timeline itself is the embedded VutuvWeb.TagLive.Timeline
          # LiveView; the controller only hands it the tag and the controls a
          # shared link may carry, since an off-router LiveView cannot read the
          # query string for itself.
          timeline_session: timeline_session(conn, tag),
          # `#Deutschland - vutuv`, and the same string as `og:title`. Every
          # tag page used to fall through to the bare site name, so the whole
          # `/tags/*` corpus shared one title — the strongest on-page signal
          # there is, spent on nothing, and a shared link previewed as "vutuv".
          # The hashtag form is what makes it a topic rather than a person: a
          # member may hold `/deutschland` as their handle, and two pages
          # titled "Deutschland" would be competing with each other.
          page_title: "#" <> Tag.display_name(tag),
          meta_description: meta_description(tag),
          # Markup mirrors the page (the profile's rule): a tag page the
          # crawlers are told to drop describes no collection to them either.
          indexable?: indexable?
        ),
      doc: fn ->
        recommended = Tag.recommended_users(tag)
        work_info_by_id = UserHelpers.work_information_map(recommended, 45)
        jobs = Jobs.list_tag_postings(tag, nil)
        timeline = timeline_doc(tag, conn.params)

        ListDocs.build_tag(
          tag,
          recommended,
          work_info_by_id,
          jobs,
          timeline.entries,
          timeline.total
        )
      end
    )
  end

  # What a search result and a link preview say under the title. An admin who
  # wrote a description for this topic wrote the better sentence, so it wins;
  # otherwise say what the page actually holds. The old copy ("Members on vutuv
  # tagged X") predates issue #946, after which the page leads with the posts
  # carrying the tag and most tag pages have no endorsed members at all — so it
  # promised a search visitor a list of people that often was not there.
  #
  # Capped at 160 characters, past which a search-result snippet is cut anyway;
  # `headline_text/2` is the app's one "make this one plain line and shorten it"
  # helper, so a description written with a bit of Markdown in the admin form
  # arrives here as prose rather than as literal asterisks.
  defp meta_description(%Tag{} = tag) do
    case UserHelpers.headline_text(tag.description, 160) do
      "" -> gettext("Posts and members on vutuv about %{tag}.", tag: Tag.display_name(tag))
      text -> text
    end
  end

  # The controls a link can carry, handed to the LiveView as strings — it
  # normalizes them itself, so a typed or stale value lands on the full list
  # rather than on an error.
  defp timeline_session(conn, tag) do
    params = conn.params

    %{
      "tag_id" => tag.id,
      "source" => params["source"],
      "sort" => params["sort"],
      "q" => params["q"],
      "from" => params["from"],
      "until" => params["until"]
    }
  end

  # The same controls for the agent formats, which have no socket: one document
  # per URL, so `/tags/berlin.md?source=fediverse` is the fediverse half exactly
  # as the HTML page shows it. `?page` is offset-paginated here (the HTML page
  # loads more over the socket instead), with an out-of-range page falling back
  # to the first rather than serving an empty document — `Vutuv.Pages`' rule
  # everywhere else, which is why the total is read before the page.
  defp timeline_doc(tag, params) do
    opts = [
      source: Timeline.normalize_source(params["source"]),
      sort: Timeline.normalize_sort(params["sort"]),
      query: Timeline.normalize_query(params["q"]),
      from: Timeline.normalize_date(params["from"]),
      until: Timeline.normalize_date(params["until"])
    ]

    total = Timeline.count(tag, opts)
    page = Pages.effective_page(params, total, Timeline.per_page())

    Timeline.page(tag, Keyword.put(opts, :page, page))
  end

  # Who the pill speaks for: the page being acted as, else the member, else
  # nobody. One decider, so the shown state and the toggle behind it cannot
  # disagree — the same shape `follower_of/1` has on the organization page.
  # `@name@tags.<host>`, or nil when the installation does not federate — which
  # is what the card renders on.
  defp tag_fediverse_handle(tag) do
    if Fediverse.federated?(tag), do: "@" <> Docs.acct(tag)
  end

  defp tag_followed?(%Organization{} = page, _member, tag),
    do: Tags.tag_followed_by_organization?(page, tag)

  defp tag_followed?(_acting_as, %User{} = member, tag), do: Tags.tag_followed?(member, tag)
  defp tag_followed?(_acting_as, _member, _tag), do: false
end
