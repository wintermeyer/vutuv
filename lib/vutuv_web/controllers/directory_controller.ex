defmodule VutuvWeb.DirectoryController do
  @moduledoc """
  The public member directory: `/system/members` is the A-Z overview plus the
  live search box (`VutuvWeb.DirectorySearchLive`, embedded with `live_render`
  so this controller keeps owning the agent-format siblings),
  `/system/members/:letter` one letter's members (paginated, sorted by last
  name). A browsable index for humans, and the crawl-friendly sibling of the
  sitemap for search engines that browse links instead of `/sitemap.xml`.

  It lists **every** member the site lists anywhere (`Directory.listed_users/0`)
  — the most-followed listing, the follower lists and `/search` never filtered
  by the search-engine opt-out, and a directory that did was the odd one out,
  missing the member somebody came here to look up. What the opt-out buys is the
  `rel="nofollow"` on that member's row (`UserHelpers.profile_rel/1`) plus the
  `X-Robots-Tag: noindex` their profile already answers with.
  """

  use VutuvWeb, :controller

  alias Vutuv.Directory
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.UserHelpers

  # Also served as Markdown / text / JSON / XML via VutuvWeb.AgentDocs.ListDocs.
  # Keep index.html/show.html and the doc builders in sync
  # (agent_docs_drift_test.exs).
  def index(conn, params) do
    entries = Directory.letter_entries()
    total = Directory.total(entries)
    query = params["q"] || ""

    # The search box's own state, handed to it as its mount session so a `?q=`
    # URL renders its results server-side — the no-JS path, and what makes a
    # search shareable and reloadable from an off-router LiveView that cannot
    # `push_patch` its own URL.
    search_session = %{"q" => query, "fields" => params["fields"], "show" => params["show"]}

    # Deliberately the listed count and nothing else. The whole membership and
    # the Fediverse head count sat beside it until 2026-08-13; both are the top
    # bar's business (`#people-total` is on this page too), and three figures
    # above the A-Z strip turned a directory into a statistics page.
    AgentDocs.respond(conn,
      html: fn conn ->
        conn
        # A search result is not a page to index: `/search` is noindexed for
        # being an endless hall of mirrors, and this one would additionally
        # publish the names of members who asked to stay out of search results.
        # The bare A-Z overview stays indexable, which is the whole point of it.
        |> noindex_search(query)
        |> render("index.html",
          page_title: gettext("Member directory"),
          entries: entries,
          total: total,
          search_session: search_session
        )
      end,
      # The agent formats answer for the directory itself, never for a query:
      # `?q=` is a person typing, and a doc that changed under it would make
      # the canonical URL name a different document every time.
      doc: fn -> ListDocs.build_directory_index(entries, total) end
    )
  end

  defp noindex_search(conn, ""), do: conn
  defp noindex_search(conn, _query), do: ContentPolicy.put_robots_header(conn, true, false)

  def show(conn, %{"letter" => letter}) do
    if Directory.valid_letter?(letter) do
      show_letter(conn, letter)
    else
      VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  defp show_letter(conn, letter) do
    %{users: users, total: total} = Directory.members_page(letter, conn.params)
    label = VutuvWeb.DirectoryHTML.display_letter(letter)
    work_info_by_id = UserHelpers.work_information_map(users, 60)
    tags_by_id = UserHelpers.tag_summary_map(users, 4)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "show.html",
          page_title: gettext("Members: %{letter}", letter: label),
          letter: letter,
          label: label,
          entries: Directory.letter_entries(),
          users: users,
          total: total,
          per_page: Directory.per_page(),
          work_info_by_id: work_info_by_id,
          tags_by_id: tags_by_id,
          following_by_id: UserHelpers.following_map(conn.assigns[:current_user], users)
        )
      end,
      doc: fn ->
        ListDocs.build_directory_letter(letter, label, users, total, work_info_by_id, tags_by_id)
      end
    )
  end
end
