defmodule VutuvWeb.TagController do
  use VutuvWeb, :controller

  alias Vutuv.Jobs
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
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
  # (anonymous view: the description, the most endorsed members and the public
  # posts carrying this tag — not the viewer-dependent "people you may know").
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

    # "Posts with this tag" (#946) is offset-paginated (`?page`). The overview —
    # description, most-endorsed members and the "Offene Stellen" jobs (#933) —
    # is the tag's front matter, so it rides only on page 1; pages 2+ are just
    # more posts. The post total is computed once and reused by both branches
    # and the pager.
    posts_total = Posts.count_tag_posts(tag)
    first_page? = Pages.effective_page(conn.params, posts_total, Posts.tag_posts_per_page()) == 1

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
          overview?: first_page?,
          open_positions:
            if(first_page?,
              do: Jobs.list_tag_postings(tag, conn.assigns[:current_user]),
              else: []
            ),
          tag_posts: Posts.list_tag_posts(tag, conn.params, total: posts_total),
          posts_total: posts_total,
          posts_per_page: Posts.tag_posts_per_page(),
          meta_description: gettext("Members on vutuv tagged %{tag}.", tag: tag.name || tag.slug)
        ),
      doc: fn ->
        recommended = if first_page?, do: Tag.recommended_users(tag), else: []
        work_info_by_id = VutuvWeb.UserHelpers.work_information_map(recommended, 45)
        jobs = if first_page?, do: Jobs.list_tag_postings(tag, nil), else: []

        ListDocs.build_tag(
          tag,
          recommended,
          work_info_by_id,
          jobs,
          Posts.list_tag_posts(tag, conn.params, total: posts_total),
          posts_total
        )
      end
    )
  end
end
