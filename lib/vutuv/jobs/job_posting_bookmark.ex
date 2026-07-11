defmodule Vutuv.Jobs.JobPostingBookmark do
  @moduledoc false
  use VutuvWeb, :model

  schema "job_posting_bookmarks" do
    belongs_to(:job_posting, Vutuv.Jobs.JobPosting)
    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end
end
