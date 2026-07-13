defmodule Vutuv.JobsFreezeComplianceTest do
  @moduledoc """
  The compliance-critical guarantee (#934): freezing a job posting strips it from
  every public and machine channel — the public board, the sitemap/JSON-LD
  indexable set and the agent-format siblings — and the public detail is
  unreachable (a 404, so there is no noindex page with JSON-LD to leak).
  Unfreezing restores all of it.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory
  import Vutuv.JobsHelpers

  alias Vutuv.Jobs

  test "a freeze pulls the posting out of every public/machine channel; unfreeze restores it" do
    posting = publish_job!()

    assert Jobs.indexable?(posting)
    assert Jobs.agent_visible?(posting)
    assert posting.id in indexable_ids()
    assert posting.id in board_ids()

    {:ok, frozen} = Jobs.admin_set_frozen(posting, true)

    refute Jobs.indexable?(frozen)
    refute Jobs.agent_visible?(frozen)
    refute frozen.id in indexable_ids()
    refute frozen.id in board_ids()

    # The public (anon + a logged-in stranger) can't see it at all → the show
    # 404s, so there is no noindex page carrying JSON-LD to leak.
    assert Jobs.fetch_visible_job_posting(frozen.slug, nil) == {:error, :not_found}

    assert Jobs.fetch_visible_job_posting(frozen.slug, insert(:activated_user)) ==
             {:error, :not_found}

    {:ok, thawed} = Jobs.admin_set_frozen(frozen, false)

    assert Jobs.indexable?(thawed)
    assert Jobs.agent_visible?(thawed)
    assert thawed.id in indexable_ids()
    assert thawed.id in board_ids()
  end

  defp indexable_ids, do: Jobs.indexable_query() |> Repo.all() |> Enum.map(& &1.id)
  defp board_ids, do: Jobs.board_page(nil, %{}).entries |> Enum.map(& &1.id)
end
