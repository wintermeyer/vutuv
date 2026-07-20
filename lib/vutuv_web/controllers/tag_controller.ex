defmodule VutuvWeb.TagController do
  use VutuvWeb, :controller

  alias Vutuv.Jobs
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

    # The tag page's "Offene Stellen" section (#933): live public postings that
    # carry this tag. The HTML page subtracts what the signed-in viewer may not
    # see (#939 exclusions / blocks); the agent formats stay the anonymous
    # public view, so the two branches load their own list (only one runs).
    #
    # "Posts with this tag" (#946): the public posts carrying the tag, the
    # anonymous view for both branches (`Posts.list_tag_posts/1` is
    # viewer-independent), so a tag used only in posts no longer opens an
    # empty page.
    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          tag: tag,
          open_positions: Jobs.list_tag_postings(tag, conn.assigns[:current_user]),
          tag_posts: Posts.list_tag_posts(tag),
          meta_description: gettext("Members on vutuv tagged %{tag}.", tag: tag.name || tag.slug)
        ),
      doc: fn ->
        recommended = Tag.recommended_users(tag)
        work_info_by_id = VutuvWeb.UserHelpers.work_information_map(recommended, 45)

        ListDocs.build_tag(
          tag,
          recommended,
          work_info_by_id,
          Jobs.list_tag_postings(tag, nil),
          Posts.list_tag_posts(tag)
        )
      end
    )
  end
end
