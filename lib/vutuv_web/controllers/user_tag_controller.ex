defmodule VutuvWeb.UserTagController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :user_tags,
    join: :tag,
    slug_param: "id",
    field: :slug,
    assign: :user_tag
  )

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show, :endorsers])

  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.UserHelpers

  # How many endorsers the tag detail page names inline (issue #1008); the rest
  # live on the paginated endorsers page, one link away.
  @endorsers_preview 12

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs). The
  # shared preload carries the endorsements the docs count and keeps the
  # order in sync with the profile page; the index adds the endorsers
  # themselves, since its rows name them (issue #895).
  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(user_tags: with_endorsers(UserTag.ordered_by_endorsements()))

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          user_tags: user.user_tags,
          endorsement_scale: max_endorsement_count(user.user_tags),
          page_title: UserHelpers.member_page_title(user, gettext("Tags"))
        )
      end,
      doc: fn -> SectionDocs.build_index(user, :tags, user.user_tags) end
    )
  end

  # The owner's editor (GET /settings/tags): add or delete, tags have no edit.
  def manage(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(user_tags: UserTag.ordered_by_endorsements())

    render(conn, "manage.html",
      user: user,
      user_tags: user.user_tags,
      as_owner?: true,
      page_title: gettext("Tags")
    )
  end

  def show(conn, %{"id" => _id}) do
    # Load the endorsers themselves, not just their count (issue #1008): the
    # detail page names who endorsed this member for this tag. Still only the
    # visible ones (issue #783), so length(endorsements) stays the right count.
    user_tag =
      conn.assigns[:user_tag]
      |> Repo.preload([:tag, endorsements: UserTagEndorsement.visible_with_endorser()])

    # Newest first (a UUID v7 endorsement id sorts by creation), so the detail
    # page and the agent-doc sibling name the same people in the same order.
    endorsers =
      user_tag.endorsements
      |> Enum.sort_by(& &1.id, :desc)
      |> Enum.map(& &1.user)

    # Show a capped preview as a normal people list; the rest lives on the
    # existing paginated endorsers page, one link away. Batch the per-row
    # work-info / follow lookups (one query each), like the listing pages.
    preview = Enum.take(endorsers, @endorsers_preview)

    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          user_tag: user_tag,
          endorsers: preview,
          endorsement_count: length(endorsers),
          work_info_by_id: UserHelpers.work_information_map(preview, 45),
          following_by_id: UserHelpers.following_map(conn.assigns[:current_user], preview),
          work_string_length: 45,
          page_title: UserHelpers.member_page_title(conn.assigns[:user], UserTag.name(user_tag))
        ),
      doc: fn -> SectionDocs.build_show(conn.assigns[:user], :tags, user_tag) end
    )
  end

  # Everyone who currently endorses this member for one tag — the public page
  # behind the profile Tags popover's "and N more" link. Viewer-independent
  # (the anonymous list), paginated like the follower / connection lists, and
  # served as Markdown / text / JSON / XML through ListDocs.build_tag_endorsers.
  def endorsers(conn, _params) do
    user = conn.assigns[:user]
    user_tag = Repo.preload(conn.assigns[:user_tag], :tag)

    %{users: endorsers, total: total, endorsed_at: endorsed_at_by_id, sort: sort, dir: dir} =
      Vutuv.Tags.endorsers_page(user_tag, conn.params)

    work_info_by_id = UserHelpers.work_information_map(endorsers, 45)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "endorsers.html",
          user: user,
          user_tag: user_tag,
          endorsers: endorsers,
          total: total,
          sort: sort,
          dir: dir,
          work_info_by_id: work_info_by_id,
          endorsed_at_by_id: endorsed_at_by_id,
          following_by_id: UserHelpers.following_map(conn.assigns[:current_user], endorsers),
          page_title:
            UserHelpers.member_page_title(
              user,
              "#{UserTag.name(user_tag)} · #{gettext("Endorsements")}"
            )
        )
      end,
      doc: fn ->
        ListDocs.build_tag_endorsers(
          user,
          user_tag,
          endorsers,
          total,
          work_info_by_id,
          endorsed_at_by_id
        )
      end
    )
  end

  # Each tag with its *visible* endorsers loaded (issue #783: a hidden or
  # unconfirmed account neither shows nor counts), so the rows and the doc
  # entries name them without a query per tag.
  defp with_endorsers(query) do
    Ecto.Query.preload(query, endorsements: ^UserTagEndorsement.visible_with_endorser())
  end

  # The best-endorsed tag's tally, which is what fills the row's avatar bar
  # (`<.endorsed_by>`): every other row's strip is drawn against it, so the page
  # ranks the tags by the length of their faces. In memory, off the preload.
  defp max_endorsement_count(user_tags) do
    user_tags
    |> Enum.map(&length(&1.endorsements))
    |> Enum.max(fn -> 0 end)
  end

  def delete(conn, %{"id" => _id}) do
    # Through the Tags.delete_user_tag/1 chokepoint so an honor tag
    # (a badge a member did not grant themselves) cannot be shed here.
    case Vutuv.Tags.delete_user_tag(conn.assigns[:user_tag]) do
      {:ok, _} ->
        conn
        |> put_flash(:info, gettext("User tag deleted successfully."))
        |> redirect(to: ~p"/settings/tags")

      {:error, :honor} ->
        conn
        |> put_flash(:error, gettext("This tag can only be removed by a site admin."))
        |> redirect(to: ~p"/settings/tags")
    end
  end
end
