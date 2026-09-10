defmodule Vutuv.MediaJobs do
  @moduledoc """
  The media-job log (issue #2103) — one row per step the media pipelines run,
  and the queries behind `/admin/media`.

  Today each pipeline keeps a status column on its own row and the only record
  of how long a step took is the server log, so "the photo scan has been stuck
  for an hour" is not a question anybody can answer from the admin area. This
  table answers it: the AI image scan, the video conversion and the post
  screenshot capture each open a row when a step begins and close it when it
  ends, and nothing ever reads a row back.

  ## Writing is best-effort, on purpose

  `start/2`, `finish/2` and `fail/2` never raise and never return an error the
  caller has to handle. Every writer here is a fire-and-forget task
  (`Vutuv.TaskSupervisor`, `Vutuv.Videos.Pipeline`'s `async_nolink`), and a log
  write that could take a video conversion down with it would be worse than no
  log at all. `finish/2` and `fail/2` also accept `nil` as the job — the same
  nil-is-a-no-op chokepoint `Vutuv.Activity.notify/2` has — so a caller may
  pass whatever `start/2` gave it without a branch.

  That swallowing is safe only **outside a transaction**, which all three
  callers are: inside one, the rescue would hide a `Postgrex.Error` that has
  already aborted the surrounding transaction, and the caller's own work would
  then fail somewhere else with a confusing error.

  A job whose process dies between `start/2` and `finish/2` simply stays
  `running`. That is not a leak to repair: a step that never finished is
  exactly what an operator opens this page to find, and the retention sweep
  clears it eventually like every other row.

  ## Retention

  90 days (`MEDIA_JOB_RETENTION_DAYS`), swept daily by
  `Vutuv.MediaJobs.Sweeper`. The table grows with every upload on the
  installation and nothing here is worth keeping for a year — the value is in
  the last few weeks, when somebody is looking at a queue that misbehaves.
  """

  import Ecto.Query
  import Vutuv.SearchText, only: [name_ilike: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.MediaJobs.MediaJob
  alias Vutuv.Pages
  alias Vutuv.Repo
  alias Vutuv.SearchText

  require Logger

  # What may open a row. A closed vocabulary rather than a free string, so a
  # typo at a call site shows up as a missing row here instead of as a second
  # kind nobody can filter by.
  @kinds ~w(image_scan video_conversion screenshot attachment_intake attachment_pages)

  # The columns the table can be sorted by — every column it shows.
  @sort_columns ~w(started member kind outcome duration)

  # `detail` is a varchar(255) like every other plain string column, and the
  # reasons that arrive here are `inspect/1` of whatever a pipeline failed on,
  # which has no bound at all. Cut rather than raise 22001 on the failure path
  # of a job that already went wrong.
  @detail_max 255

  @jobs_per_page 50

  @doc "How many jobs one page of `/admin/media` shows."
  def jobs_per_page, do: @jobs_per_page

  @doc """
  How long a job row is kept, in days. Per-installation
  (`MEDIA_JOB_RETENTION_DAYS`, read in `config/runtime.exs`), 90 by default.
  """
  def retention_days, do: Application.get_env(:vutuv, :media_job_retention_days, 90)

  # ── Writing ──

  @doc """
  Opens a job row and answers it, or `nil` when nothing could be written.

  `kind` must be one of the declared kinds. `opts`:

    * `:subject_type` / `:subject_id` — the row this step works on, as the
      pipeline names it (`"image_scan"`, `"post_video"`, `"post_screenshot"`).
    * `:user_id` — the member whose media it is, when there is one.
    * `:post_id` — the post the work belongs to, when there is one. This is
      what the admin page links to.
    * `:detail` — anything worth saying about the step before it has an
      outcome.

  Pass the answer straight to `finish/2` or `fail/2`; it may be `nil` and both
  of those take that.
  """
  def start(kind, opts \\ [])

  def start(kind, opts) when kind in @kinds do
    %MediaJob{
      kind: kind,
      status: "running",
      subject_type: opts[:subject_type],
      subject_id: opts[:subject_id],
      user_id: opts[:user_id],
      post_id: opts[:post_id],
      detail: clip(opts[:detail]),
      started_at: DateTime.utc_now()
    }
    |> Repo.insert()
    |> case do
      {:ok, job} -> job
      {:error, changeset} -> log_refusal(kind, changeset.errors)
    end
  rescue
    exception -> log_refusal(kind, Exception.message(exception))
  end

  def start(kind, _opts) do
    Logger.error("media job with undeclared kind #{inspect(kind)}")
    nil
  end

  @doc """
  Closes a job as done. `opts[:detail]` says how it ended in words ("safe",
  "rejected: nudity"). Always `:ok`, including for a `nil` job.
  """
  def finish(job, opts \\ []), do: close(job, "done", opts[:detail])

  @doc """
  Closes a job as failed. `reason` is whatever the pipeline failed on — a
  string, an atom or a tuple — and is stored as text, cut to fit its column.
  Always `:ok`, including for a `nil` job.
  """
  def fail(job, reason), do: close(job, "failed", reason)

  # Scoped to a job that is still running, in the UPDATE itself: a retry that
  # re-runs the tail of a step must not move a stamp that already means
  # something, and a `%MediaJob{}` held across a long encode says nothing about
  # what the row looks like now.
  defp close(%MediaJob{} = job, status, detail) do
    from(j in MediaJob, where: j.id == ^job.id and j.status == "running")
    |> Repo.update_all(
      set: [status: status, finished_at: DateTime.utc_now(), detail: clip(detail)]
    )

    :ok
  rescue
    exception ->
      Logger.error("media job #{status} not recorded: #{Exception.message(exception)}")
      :ok
  end

  defp close(_no_job, _status, _detail), do: :ok

  defp clip(nil), do: nil
  defp clip(detail) when is_binary(detail), do: String.slice(detail, 0, @detail_max)

  # Bounded at the source: a reason can be any term, and building its whole
  # inspect string only to cut it is work the printable limit does for free.
  defp clip(detail) do
    detail |> inspect(printable_limit: @detail_max) |> String.slice(0, @detail_max)
  end

  defp log_refusal(kind, reason) do
    Logger.error("media job #{kind} not recorded: #{inspect(reason)}")
    nil
  end

  # ── Reading (the admin page) ──

  @doc """
  How long a job took, in milliseconds — and for one still running, how long it
  has been going, which is the number the page is opened to see.

  One definition for both, because the Duration column has to mean the same
  thing while a job runs as it does once it ends; the duration **sort** builds
  the same expression in SQL for the same reason.
  """
  def elapsed_ms(%MediaJob{started_at: started_at} = job) do
    max(DateTime.diff(job.finished_at || DateTime.utc_now(), started_at, :millisecond), 0)
  end

  @doc """
  The `/admin/media` view as a map, read from the URL params: one search over
  member, kind and outcome, plus the sort column and direction. Anything the
  URL invents falls back to the default rather than reaching a query.
  """
  def filters(params) when is_map(params) do
    sort = validated_sort(params["sort"])

    %{
      q: Pages.blank_to_nil(params["q"]),
      sort: sort,
      dir: validated_dir(params["dir"]) || default_dir(sort)
    }
  end

  @doc """
  The direction a column sorts in when it is picked for the first time: the
  time and the duration largest-first (a log is read for what just happened and
  for what is taking too long), the text columns A-Z.
  """
  def default_dir(column) when column in ~w(started duration), do: "desc"
  def default_dir(_text_column), do: "asc"

  @doc "How many jobs match `filters` (for the pager)."
  def count(filters \\ %{}) do
    filters |> base() |> Repo.aggregate(:count)
  end

  @doc """
  One page of the log: searched, sorted, paginated, with each job's member and
  post preloaded so the table can name and link both.
  """
  def page(filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @jobs_per_page)
    base = base(filters)
    total = Keyword.get(opts, :total) || Repo.aggregate(base, :count)

    base
    # The post's own author comes along, because `Vutuv.Posts.path/1` needs it
    # to know whether the permalink is a member's or an organization's — and
    # left unloaded it falls back to a lookup per row, which on a 50-row page is
    # fifty of them.
    |> preload([:user, post: [:user, :organization]])
    |> order(filters)
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  defp base(filters) do
    from(j in MediaJob, as: :job)
    |> search(Map.get(filters, :q))
  end

  defp search(query, nil), do: query

  defp search(query, term) do
    like = SearchText.contains(term)

    query
    |> join_member()
    |> where(
      [job: j, member: m],
      ilike(j.kind, ^like) or ilike(j.status, ^like) or ilike(j.detail, ^like) or
        ilike(j.subject_type, ^like) or ilike(m.username, ^like) or
        name_ilike(m.first_name, m.last_name, ^like)
    )
  end

  # A LEFT join, and that is the whole point of writing it out: `user_id` is
  # nullable (a screenshot of a remote post has no member here), so an inner
  # join would silently drop those rows from a member-sorted view — the
  # nullable-column trap this codebase has paid for five times. Added at most
  # once, so a searched *and* member-sorted view does not join `users` twice.
  defp join_member(query) do
    if has_named_binding?(query, :member) do
      query
    else
      join(query, :left, [job: j], m in User, on: m.id == j.user_id, as: :member)
    end
  end

  # The row's own id is the last key of every sort: it is a UUID v7, so it
  # encodes creation order, which keeps offset pagination stable when the
  # visible values tie (a burst of screenshots claimed in one drain).
  defp order(query, filters) do
    dir = direction(Map.get(filters, :dir))

    case Map.get(filters, :sort) do
      "member" ->
        # Nulls last in both directions: an ownerless job has no name to file
        # under, and letting NULL take the top of the list would bury every row
        # that does.
        query
        |> join_member()
        |> order_by([job: j, member: m], [{^nulls_last(dir), m.username}, desc: j.id])

      "kind" ->
        order_by(query, [job: j], [{^dir, j.kind}, desc: j.id])

      "outcome" ->
        order_by(query, [job: j], [{^dir, j.status}, desc: j.id])

      "duration" ->
        order_by_duration(query, dir)

      _started ->
        order_by(query, [job: j], [{^dir, j.started_at}, {^dir, j.id}])
    end
  end

  # "Longest first" is the gesture that answers "what is taking too long", so a
  # job that has been running for three hours has to come **first** — it is the
  # one the operator came for. Sorting on the stored end stamp alone would file
  # every unfinished job under NULL and push exactly those rows off the last
  # page. So the sort computes the same elapsed time `elapsed_ms/1` shows in the
  # cell, from one `now` for the whole query.
  defp order_by_duration(query, dir) do
    now = DateTime.utc_now()

    order_by(
      query,
      [job: j],
      [
        {^dir,
         fragment(
           "coalesce(?, ?) - ?",
           j.finished_at,
           type(^now, :utc_datetime_usec),
           j.started_at
         )},
        desc: j.id
      ]
    )
  end

  defp direction("asc"), do: :asc
  defp direction(_desc), do: :desc

  defp nulls_last(:asc), do: :asc_nulls_last
  defp nulls_last(:desc), do: :desc_nulls_last

  defp validated_sort(sort) when is_binary(sort) do
    if sort in @sort_columns, do: sort, else: "started"
  end

  defp validated_sort(_sort), do: "started"

  defp validated_dir(dir) when dir in ~w(asc desc), do: dir
  defp validated_dir(_other), do: nil

  # ── Retention ──

  @doc """
  Deletes every job older than `retention_days/0` and returns how many went.
  Called by `Vutuv.MediaJobs.Sweeper`; public so a test (and an operator's
  `bin/vutuv rpc`) can run it directly.
  """
  def delete_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)
    {count, _} = Repo.delete_all(from(j in MediaJob, where: j.started_at < ^cutoff))
    count
  end
end
