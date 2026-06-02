defmodule Vutuv.JobPostings do
  @moduledoc """
  The JobPostings context. Handles job postings and their tags.
  """

  alias Vutuv.JobPostings.JobPosting
  alias Vutuv.JobPostings.JobPostingTag
  alias Vutuv.Repo

  # ── Job Postings ──

  def list_job_postings do
    Repo.all(JobPosting)
  end

  def get_job_posting!(id), do: Repo.get!(JobPosting, id)

  def get_job_posting_by_slug(slug) do
    Repo.get_by(JobPosting, slug: slug)
  end

  def create_job_posting(attrs) do
    %JobPosting{} |> JobPosting.changeset(attrs) |> Repo.insert()
  end

  def update_job_posting(%JobPosting{} = posting, attrs) do
    posting |> JobPosting.changeset(attrs) |> Repo.update()
  end

  def delete_job_posting!(%JobPosting{} = posting), do: Repo.delete!(posting)

  def get_postings_for_user(user), do: JobPosting.get_postings_for_user(user)

  def get_important_tags(job), do: JobPosting.get_important_tags(job)

  # ── Job Posting Tags ──

  def get_job_posting_tag!(id), do: Repo.get!(JobPostingTag, id)

  def create_job_posting_tag(attrs) do
    %JobPostingTag{} |> JobPostingTag.changeset(attrs) |> Repo.insert()
  end

  def delete_job_posting_tag!(%JobPostingTag{} = tag), do: Repo.delete!(tag)
end
