defmodule VutuvWeb.AgentDocs.JobBoardDoc do
  @moduledoc """
  The public job board (`/jobs`, issue #933) as an agent document. The
  anonymous public view: only live, `everyone`, `geo?` postings (never a
  `members` or hidden one — `Vutuv.Jobs.agent_board_page/1` enforces it), newest
  first, cursor-paginated. Each entry carries the structured location, salary
  and tag fields (`VutuvWeb.AgentDocs.JobPostingDoc.summary/1`) so an agent can
  filter client-side; a `next` link walks to the following page.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.JobPostingDoc

  def build(postings, next_cursor \\ nil) do
    AgentDocs.doc_meta("job_board", "/jobs")
    |> Map.merge(%{
      title: gettext("Jobs"),
      description: gettext("Open positions on vutuv, newest first."),
      count: length(postings),
      next: next_url(next_cursor),
      postings: Enum.map(postings, &JobPostingDoc.summary/1)
    })
  end

  defp next_url(nil), do: nil

  defp next_url(cursor),
    do: AgentDocs.abs_url("/jobs?" <> URI.encode_query(%{"cursor" => cursor}))
end
