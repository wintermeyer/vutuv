defmodule Vutuv.MediaJobs.MediaJob do
  @moduledoc """
  One step a media pipeline ran (issue #2103): what it was, what it worked on,
  when it started and finished, how long it took and how it ended.

  A plain log. The pipelines write rows here and never read them back, so
  nothing about how they behave depends on this table being there — which is
  what lets `Vutuv.MediaJobs` swallow every error instead of taking the work
  down with it.

  `subject_type` + `subject_id` name the row the step worked on without a
  foreign key to it: the subject lives in a different table per kind, and a log
  row has to outlive the picture it is about. `user_id` and `post_id` are the
  two real references, and both are nullable — a screenshot of a remote post
  belongs to no member here, and a clip has no post until it is published.
  There is no changeset: every field is set programmatically by
  `Vutuv.MediaJobs`, the same way `Vutuv.Moderation.ImageScan` is.
  """

  use VutuvWeb, :model

  schema "media_jobs" do
    field(:kind, :string)
    field(:status, :string, default: "running")

    field(:subject_type, :string)
    field(:subject_id, Vutuv.UUIDv7)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:post, Vutuv.Posts.Post)

    field(:detail, :string)

    # How long it took is these two, never a third column: a stored duration
    # could only ever repeat their difference, and the page and the sort both
    # need the running case anyway, which no stored value can hold.
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
  end
end
