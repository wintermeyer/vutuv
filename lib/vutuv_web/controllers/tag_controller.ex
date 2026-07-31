defmodule VutuvWeb.TagController do
  use VutuvWeb, :controller

  alias Vutuv.Jobs
  alias Vutuv.Pages
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.Timeline
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ContentPolicy

  plug(VutuvWeb.Plug.ResolveSlug,
    slug: "slug",
    model: Vutuv.Tags.Tag,
    assign: :tag,
    field: :slug
  )

  def index(conn, _params) do
    tags_count = Repo.aggregate(Tag, :count)

    tags =
      from(t in Tag, order_by: fragment("lower(coalesce(?, ?))", t.name, t.slug))
      |> Pages.paginate(conn.params, tags_count)
      |> Repo.all()

    render(conn, "index.html", tags: tags, tags_count: tags_count)
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
    following_tag? = not is_nil(current_user) and Tags.tag_followed?(current_user, tag)
    tag_follower_count = Tags.tag_follower_count(tag)

    # A tag page below the search-engine bar (fewer than
    # Tags.min_indexable_members/0 visible members and no public post) is a
    # thin near-duplicate in a search index; thousands of them sat in Search
    # Console as "crawled - currently not indexed". It stays served and
    # linkable, but carries noindex (on every format) so crawlers drop it
    # deliberately; the sitemap advertises only the tags above the bar.
    conn =
      if Tags.indexable_tag?(tag),
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
          open_positions: Jobs.list_tag_postings(tag, conn.assigns[:current_user]),
          # The timeline itself is the embedded VutuvWeb.TagLive.Timeline
          # LiveView; the controller only hands it the tag and the controls a
          # shared link may carry, since an off-router LiveView cannot read the
          # query string for itself.
          timeline_session: timeline_session(conn, tag),
          meta_description: gettext("Members on vutuv tagged %{tag}.", tag: tag.name || tag.slug)
        ),
      doc: fn ->
        recommended = Tag.recommended_users(tag)
        work_info_by_id = VutuvWeb.UserHelpers.work_information_map(recommended, 45)
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
end
