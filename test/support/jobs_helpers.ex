defmodule Vutuv.JobsHelpers do
  @moduledoc """
  Test helpers for job postings (issue #932): a poster old and confirmed enough
  to clear the anti-abuse gate, and a one-call published posting.
  """

  import Ecto.Query
  import Vutuv.Factory

  alias Vutuv.Accounts.User
  alias Vutuv.Jobs
  alias Vutuv.Repo

  @doc "A confirmed account old enough to publish (backdated 5 days)."
  def poster_fixture(attrs \\ []) do
    user = insert(:activated_user, attrs)
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -5 * 86_400, :second)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [inserted_at: old])
    Repo.reload!(user)
  end

  @doc "Default publish attrs (an on-site Cologne posting), merged with `overrides`."
  def job_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Backend Engineer (m/w/d)",
        "employment_type" => "full_time",
        "workplace_type" => "onsite",
        "zip_code" => "50667",
        "city" => "Köln",
        "country" => "DE",
        "salary_min" => "55000",
        "salary_max" => "70000",
        "salary_currency" => "EUR",
        "salary_period" => "year",
        "apply_kind" => "message"
      },
      overrides
    )
  end

  @doc """
  Creates and publishes a posting, returning the reloaded posting. `opts` is
  threaded into `create_draft`/`publish` — pass `organization:` an `%Organization{}`
  the `user` holds a role on to attribute the posting to it.
  """
  def publish_job!(user \\ nil, overrides \\ %{}, opts \\ []) do
    user = user || poster_fixture()
    {:ok, draft} = Jobs.create_draft(user, %{"title" => job_attrs(overrides)["title"]}, opts)
    {:ok, posting} = Jobs.publish(draft, user, job_attrs(overrides), opts)
    posting
  end
end
