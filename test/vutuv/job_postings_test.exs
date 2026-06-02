defmodule Vutuv.JobPostingsTest do
  use Vutuv.DataCase

  alias Vutuv.JobPostings

  describe "job_postings" do
    test "get_job_posting!/1 returns the job posting" do
      user = insert(:user)
      job = insert(:job_posting, user: user)
      assert JobPostings.get_job_posting!(job.id).id == job.id
    end

    test "get_job_posting_by_slug/1 returns by slug" do
      user = insert(:user)
      job = insert(:job_posting, user: user, slug: "test-job")
      assert JobPostings.get_job_posting_by_slug("test-job").id == job.id
    end

    test "get_job_posting_by_slug/1 returns nil for unknown slug" do
      assert JobPostings.get_job_posting_by_slug("nonexistent") == nil
    end
  end
end
