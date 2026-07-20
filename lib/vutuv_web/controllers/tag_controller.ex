defmodule VutuvWeb.TagController do
  use VutuvWeb, :controller

  alias Vutuv.Jobs
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Tags.Tag
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs

  plug(VutuvWeb.Plug.ResolveSlug,
    slug: "slug",
    model: Vutuv.Tags.Tag,
    assign: :tag,
    field: :slug
  )

  def index(conn, _params) do
    tags_count = Repo.one(from(t in Tag, select: count(t.id)))

    tags =
      from(t in Tag, order_by: fragment("lower(coalesce(?, ?))", t.name, t.slug))
      |> Vutuv.Pages.paginate(conn.params, tags_count)
      |> Repo.all()

    render(conn, "index.html", tags: tags, tags_count: tags_count)
  end

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs
  # (anonymous view: the description, the most endorsed members and the public
  # posts carrying this tag — not the viewer-dependent "people you may know").
  # Keep show.html and the doc builder in sync (agent_docs_drift_test.exs).
  def show(conn, _params) do
    tag = conn.assigns[:tag]

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
