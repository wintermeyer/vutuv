defmodule VutuvWeb.TagController do
  use VutuvWeb, :controller

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
      from(t in Tag)
      |> Vutuv.Pages.paginate(conn.params, tags_count)
      |> Repo.all()

    render(conn, "index.html", tags: tags, tags_count: tags_count)
  end

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs
  # (anonymous view: the description plus the most endorsed members, not the
  # viewer-dependent "people you may know"). Keep show.html and the doc
  # builder in sync (agent_docs_drift_test.exs).
  def show(conn, _params) do
    tag = conn.assigns[:tag]

    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> AgentDocs.put_html_alternates()
        |> render("show.html", tag: tag)

      format ->
        recommended = Tag.recommended_users(tag)
        work_info_by_id = VutuvWeb.UserHelpers.work_information_map(recommended, 45)
        doc = ListDocs.build_tag(tag, recommended, work_info_by_id)
        AgentDocs.send_doc(conn, format, doc)
    end
  end
end
