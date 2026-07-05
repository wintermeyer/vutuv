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
  plug(:scrub_params, "tag_param" when action in [:create])

  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.UserHelpers

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs). The
  # shared preload carries the endorsements the docs count and keeps the
  # order in sync with the profile page.
  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(user_tags: UserTag.ordered_by_endorsements())

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html", as_owner?: false, user: user, user_tags: user.user_tags)
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

  # The add-tag *form* lives in `VutuvWeb.TagNewLive` (/settings/tags/new),
  # which previews the parsed tags while the member types and saves over its
  # socket (issue #848). This dead create stays for plain-HTTP callers — the
  # public tag page's "Add this tag" button POSTs here (issue #844 pinned the
  # URL) — and always redirects; the inline-error re-render retired with the
  # dead form template. Same parse + case-insensitive dedupe as the LiveView,
  # so both entry points attach the same tags for the same input.
  def create(conn, %{"tag_param" => tag_param}) do
    user = conn.assigns[:current_user]

    parsed =
      tag_param["value"]
      |> Vutuv.Tags.parse_tag_names()
      |> Enum.uniq_by(&String.downcase/1)

    case parsed do
      [] ->
        conn
        |> put_flash(:error, gettext("Please enter a tag."))
        |> redirect(to: ~p"/settings/tags/new")

      names ->
        results = Enum.map(names, &Vutuv.Tags.add_user_tag(user, &1))
        failures = Enum.count(results, &match?({:error, _}, &1))
        successes = length(results) - failures
        kind = if successes == 0, do: :error, else: :info

        conn
        |> put_flash(kind, UserHelpers.tags_added_flash(successes, failures))
        |> redirect(to: ~p"/settings/tags")
    end
  end

  def show(conn, %{"id" => _id}) do
    # Count only visible endorsers (issue #783); the agent doc derives the
    # endorsement count from length(endorsements) on this plain preload.
    user_tag =
      conn.assigns[:user_tag]
      |> Repo.preload([:tag, endorsements: UserTagEndorsement.visible()])

    AgentDocs.respond(conn,
      html: &render(&1, "show.html", user_tag: user_tag),
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
          following_by_id: UserHelpers.following_map(conn.assigns[:current_user], endorsers)
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
