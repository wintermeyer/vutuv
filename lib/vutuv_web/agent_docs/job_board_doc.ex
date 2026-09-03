defmodule VutuvWeb.AgentDocs.JobBoardDoc do
  @moduledoc """
  The public job board (`/jobs`, issue #933) as an agent document. The
  anonymous public view: only live, `everyone`, `geo?` postings (never a
  `members` or hidden one — `Vutuv.Jobs.agent_board_page/1` enforces it), newest
  first, cursor-paginated. Each entry carries the structured location, salary
  and tag fields (`VutuvWeb.AgentDocs.JobPostingDoc.summary/1`) so an agent can
  filter client-side; a `next` link walks to the following page.

  With no posting at all the HTML board shows the other side of the market
  instead — a random handful of the members who said they are available, and
  the fields they carry — so the document carries the same two facts under
  `open_to_offers` and `fields`. An agent asked "is anybody hiring on vutuv?"
  then gets the honest answer *and* the reason to look further, exactly like a
  reader. `open_to_offers` is the drawn people and nothing else: with a random
  sample, how many there are in all is a number neither the page nor this
  document can back up with rows.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.JobPostingDoc
  alias VutuvWeb.UserHelpers

  # Tags per available member, the same glance the HTML board shows beside a
  # name (`VutuvWeb.JobBoardLive`); the whole list is on their tag page.
  @tags_shown 3

  @doc """
  The board document. `reach` is the empty-board companion (`%{people:,
  fields:}` from `Vutuv.Jobs.board_reach/1`, anonymous view) or nil on a board
  that has postings.
  """
  def build(postings, next_cursor \\ nil, reach \\ nil) do
    AgentDocs.doc_meta("job_board", "/jobs")
    |> Map.merge(%{
      title: gettext("Jobs"),
      description: gettext("Open positions on vutuv, newest first."),
      count: length(postings),
      next: next_url(next_cursor),
      postings: Enum.map(postings, &JobPostingDoc.summary/1)
    })
    |> put_reach(reach)
  end

  defp put_reach(doc, nil), do: doc

  defp put_reach(doc, %{people: people, fields: fields}) do
    work_info = UserHelpers.work_information_map(people, 45)
    tags = UserHelpers.tag_summary_map(people, @tags_shown)

    Map.merge(doc, %{
      open_to_offers: Enum.map(people, &person_entry(&1, work_info, tags)),
      fields:
        Enum.map(fields, fn {tag, members} ->
          %{name: tag.name, url: AgentDocs.abs_url("/tags/" <> tag.slug), members: members}
        end)
    })
  end

  # The shared listing shape (`AgentDocs.person_entry/3`) plus the availability
  # this document is about. Only members whose status is open to `everyone`
  # reach it — `Vutuv.Jobs.board_reach/1` is asked with a nil viewer.
  defp person_entry(user, work_info, tags) do
    AgentDocs.person_entry(user, work_info, tags)
    |> Map.put(:employment_status, user.employment_status)
    |> Map.put(:desired_workplace_types, user.desired_workplace_types)
  end

  defp next_url(nil), do: nil

  defp next_url(cursor),
    do: AgentDocs.abs_url("/jobs?" <> URI.encode_query(%{"cursor" => cursor}))
end
