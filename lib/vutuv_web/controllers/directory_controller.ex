defmodule VutuvWeb.DirectoryController do
  @moduledoc """
  The public member directory: `/system/members` is the A-Z overview,
  `/system/members/:letter` one letter's members (paginated, sorted by last name).
  The crawl-friendly sibling of the sitemap for search engines that browse
  links instead of `/sitemap.xml` — and a browsable index for humans. Only
  the crawlable member set shows up (`Vutuv.Directory.indexable_users/0`);
  members who opted out of search engines are never listed.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Directory
  alias Vutuv.Fediverse
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.UserHelpers

  # Also served as Markdown / text / JSON / XML via VutuvWeb.AgentDocs.ListDocs.
  # Keep index.html/show.html and the doc builders in sync
  # (agent_docs_drift_test.exs).
  def index(conn, _params) do
    entries = Directory.letter_entries()
    total = Directory.total(entries)

    # The whole membership beside the listed part, so the directory's total
    # cannot be read as "this is how many members there are". It comes from
    # Accounts.count_users/0, the same definition the member half of the top
    # bar's live people total uses, or the two figures on one page would
    # disagree.
    members_total = Accounts.count_users()

    # The other half of that pill, and the reason this page names it at all:
    # the top bar advertises members plus the distinct Fediverse accounts
    # following them, and this is the page it links to. Without the third
    # figure a visitor clicking "5,920 people" would land on a page that only
    # ever says 5,508 and looks like it lost 412 of them.
    fediverse_total = Fediverse.distinct_follower_count()

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          page_title: gettext("Member directory"),
          entries: entries,
          total: total,
          members_total: members_total,
          fediverse_total: fediverse_total
        )
      end,
      doc: fn ->
        ListDocs.build_directory_index(entries, total, members_total, fediverse_total)
      end
    )
  end

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
