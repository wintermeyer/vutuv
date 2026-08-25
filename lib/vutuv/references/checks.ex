defmodule Vutuv.References.Checks do
  @moduledoc """
  The queue behind the Arbeitszeugnis analysis.

  A check occupies the model for minutes — measured 45 s on a warm GPU
  instance, ~11 minutes on CPU — and a typical Ollama runs one request at a
  time. So this is a real queue with a real wait, and the member is told where
  they stand in it (`queue_position/1`) rather than being shown a spinner that
  means nothing.

  Every state change broadcasts on the member's own `Vutuv.Activity` topic, so
  the LiveView follows the row without polling.

  Errors are two-class, exactly as in the image-moderation queue:

    * `{:service, reason}` — the model is unreachable or timed out. Nothing is
      wrong with this Zeugnis; retried at a flat pace for ever (the same 300s
      the image-moderation and translation queues use), and the attempt is
      deliberately not counted against the cap. That last part is why the pace
      is flat and not a ladder: nothing on this path writes `attempts`, so
      indexing a ladder by it stayed on the first rung whatever happened.
    * `{:analysis, reason}` — this run cannot be trusted (truncated prompt,
      misconfigured window, empty answer). Counted, and at the cap the check
      fails visibly rather than looping forever on an unchanged
      misconfiguration.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Vutuv.AccountEvents
  alias Vutuv.Activity
  alias Vutuv.JobReferenceDocument
  alias Vutuv.References.Analyst
  alias Vutuv.References.Check
  alias Vutuv.References.CheckWorker
  alias Vutuv.References.JobReference
  alias Vutuv.References.TextExtraction
  alias Vutuv.Repo

  # How many due checks one drain picks up. One, deliberately: the model
  # handles a single request at a time anyway, and a small batch keeps the
  # queue position honest.
  @batch 1

  # A running check stamps `heartbeat_at` this often, and counts as orphaned
  # once it has been silent for `@stale_after_seconds`.
  #
  # The pair replaces a single "surely dead by now" cutoff of one hour, which
  # was the only safe guess while the row carried no liveness signal at all: an
  # inference legitimately takes up to 15 minutes, so anything shorter would
  # have re-queued work that was still running, and anything that long left a
  # member watching an hourglass for an hour after a deploy stopped the release
  # mid-check. A heartbeat separates "slow" from "gone", so recovery can be
  # quick without ever cutting off a live run. Five times the interval, so a
  # loaded box missing a beat or two changes nothing.
  @heartbeat_interval_ms :timer.minutes(1)
  @stale_after_seconds 300

  # Analysis-class failures tolerated before a check is given up on.
  @max_attempts 3

  # Service failures (Ollama down/unreachable) retry forever at this flat pace,
  # exactly like the two sibling queues — `Moderation.ImageScans` and
  # `Translations` both use 300s for the same case.
  #
  # This used to be a four-rung "backoff ladder" indexed by `check.attempts`,
  # and it never climbed: a service failure is deliberately not counted against
  # the cap, so nothing on that path ever wrote `attempts` and the delay was 60s
  # for ever — five times the pace of the queues beside it, for as long as the
  # model stayed down. The analysis path caps at three attempts, so it only ever
  # read the first two rungs; the last two were unreachable from either caller.
  @service_retry_seconds 300

  # The analysis-failure backoff, in seconds — one rung per counted attempt, and
  # `@max_attempts` is 3, so these are all of them.
  @analysis_backoff [60, 300]

  # Everyone waiting shares one queue, so "two ahead of you" goes stale the
  # moment somebody *else's* check finishes — and those transitions never touch
  # the waiting member's own `"user:<id>"` topic. Hence a queue-wide topic, the
  # `Vutuv.DayClock` arrangement: one named subject, broadcast by the module
  # that owns it, subscribed by whoever displays it.
  @queue_topic "reference_checks:queue"

  @doc """
  Subscribes the caller to queue movements.

  A `:queue_changed` message arrives whenever a check leaves the waiting set,
  which is exactly when everybody behind it moves up one.
  """
  def subscribe_queue, do: Phoenix.PubSub.subscribe(Vutuv.PubSub, @queue_topic)

  defp broadcast_queue_changed do
    Phoenix.PubSub.broadcast(Vutuv.PubSub, @queue_topic, :queue_changed)
  end

  @doc "Whether this installation offers the AI check at all."
  def enabled?, do: Application.get_env(:vutuv, :reference_checks_enabled, true)

  # The allowance window. Rolling rather than a calendar day, which is what
  # `next_slot_at/1` and the member-facing copy both read, so the rule and the
  # sentence describing it cannot drift apart.
  @window_seconds 24 * 3_600

  @doc "The length of the allowance window in seconds."
  def window_seconds, do: @window_seconds

  @doc "How many checks one member may start inside the allowance window."
  def daily_limit, do: Application.get_env(:vutuv, :reference_checks_per_day, 10)

  @doc """
  The identity of a Zeugnis text — what binds a result to what produced it.

  Taken over the *canonical* text (`JobReference.normalize_body/1`), because
  the question this answers is "is this the same text", not "are these the same
  bytes". A `<textarea>` hands its line breaks back as CRLF, so hashing the raw
  value made every save of an entry — a corrected title, the visibility tick, a
  CV link — report every earlier review as outdated.
  """
  def fingerprint(nil), do: nil

  def fingerprint(body) when is_binary(body) do
    :sha256
    |> :crypto.hash(JobReference.normalize_body(body))
    |> Base.encode16(case: :lower)
  end

  ## Enqueueing

  @doc """
  Queues a check for `reference`.

  Refuses, without creating a row, when:

    * `:already_queued` — one is already waiting or running. The partial
      unique index is what actually guarantees this; a double-clicked button
      must not buy two slots on a queue this slow.
    * `:no_body` — there is no text to analyse yet.
    * `:unsupported_country` — the prompt covers one country's employment law
      and this Zeugnis was issued elsewhere (see `Vutuv.References`).
    * `:rate_limited` — the member has used their allowance for the day.
    * `:disabled` — this installation runs no check.
  """
  def enqueue(%JobReference{} = reference) do
    with :ok <- ensure_enabled(),
         :ok <- ensure_body(reference),
         :ok <- ensure_country(reference),
         :ok <- ensure_within_daily_limit(reference),
         {:ok, check} <- insert(reference) do
      broadcast(check)
      CheckWorker.nudge()
      {:ok, check}
    end
  end

  defp ensure_enabled, do: if(enabled?(), do: :ok, else: {:error, :disabled})

  # Text *or* something to read it from. A member who uploaded a scan has not
  # given us text yet, but they have given us everything we need — refusing
  # them here and telling them to "paste the text" made them do by hand what
  # the check is about to do anyway.
  defp ensure_body(%JobReference{} = reference) do
    cond do
      has_text?(reference) -> :ok
      JobReference.document?(reference) -> :ok
      true -> {:error, :no_body}
    end
  end

  defp has_text?(%JobReference{body: body}), do: is_binary(body) and String.trim(body) != ""

  defp ensure_country(reference) do
    if Vutuv.References.check_supported?(reference),
      do: :ok,
      else: {:error, :unsupported_country}
  end

  # Counted over checks *started* in the window rather than rows currently
  # present, so deleting a Zeugnis does not hand back allowance.
  defp ensure_within_daily_limit(%JobReference{user_id: user_id}) do
    used = Repo.aggregate(within_window(user_id), :count)

    if used < daily_limit(), do: :ok, else: {:error, :rate_limited}
  end

  defp within_window(user_id) do
    since = DateTime.add(DateTime.utc_now(:second), -@window_seconds, :second)

    from(c in Check, where: c.user_id == ^user_id and c.queued_at >= ^since)
  end

  @doc """
  When the member's next review slot opens, or nil while they still have one.

  The oldest check inside the window plus the window: the allowance is a
  **rolling** #{div(@window_seconds, 3_600)} hours, not a calendar day, so
  a member who used the last slot at 23:00 is free again at 23:00 the next
  day and not at midnight. The copy says so because this says so — it is the
  same number both times.
  """
  def next_slot_at(user_id) when is_binary(user_id) do
    oldest =
      user_id
      |> within_window()
      |> order_by([c], asc: c.queued_at)
      |> limit(1)
      |> select([c], c.queued_at)
      |> Repo.one()

    if oldest, do: DateTime.add(oldest, @window_seconds, :second)
  end

  def next_slot_at(_user_id), do: nil

  defp insert(%JobReference{} = reference) do
    now = DateTime.utc_now(:second)

    %Check{}
    |> Ecto.Changeset.change(%{
      job_reference_id: reference.id,
      user_id: reference.user_id,
      status: "pending",
      body_fingerprint: fingerprint(reference.body),
      queued_at: now
    })
    # Declared so the partial unique index comes back as a changeset error
    # rather than raising: two clicks on the button is an ordinary thing for a
    # member to do, not an exception.
    |> Ecto.Changeset.unique_constraint(:job_reference_id,
      name: :reference_checks_one_open_per_reference_index
    )
    |> Repo.insert()
    |> case do
      {:ok, check} ->
        {:ok, check}

      # Something else queued this Zeugnis between our look and our write.
      {:error, _changeset} ->
        {:error, :already_queued}
    end
  end

  ## Reading

  @doc "The newest check for a Zeugnis, whatever its state, or nil."
  def latest_for(%JobReference{id: id}), do: latest_for(id)

  def latest_for(reference_id) when is_binary(reference_id) do
    Check
    |> where([c], c.job_reference_id == ^reference_id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  How many checks are ahead of this one, or nil when it is not waiting.

  Zero means "next". A running check answers nil, because it is no longer
  waiting for anything.
  """
  # Compares ids, not `inserted_at`: `timestamps()` has second resolution, so
  # three checks queued in the same second are indistinguishable by time and
  # every one of them would report "you are next". Ids are UUID v7, whose
  # leading bits are the creation timestamp, so id order *is* queue order and
  # is unique besides.
  def queue_position(%Check{status: "pending"} = check) do
    Repo.aggregate(
      from(c in Check, where: c.status == "pending" and c.id < ^check.id),
      :count
    )
  end

  def queue_position(%Check{}), do: nil

  # How many finished checks the duration estimate looks back over. Enough to
  # even out one slow run, few enough that the answer follows a hardware change
  # (a GPU swap, a bigger model) within a day rather than a quarter.
  @duration_sample 20

  @doc """
  How long a check has really been taking on this installation, in
  milliseconds, or nil while none has finished yet.

  The **median** of the last #{@duration_sample} finished runs, not the mean:
  the same document takes ~45 s on a warm GPU and ~11 minutes on a cold CPU
  instance, and one such outlier would otherwise double the number every member
  is quoted. Measured end to end (`duration_ms` is stamped by
  `Vutuv.References.Analyst` around the request), so it already includes
  whatever prefill the model needed.

  Used for two things: telling a waiting member roughly how long this takes on
  *this* installation instead of a hardcoded "a few minutes", and answering the
  same question for the operator out of real data.
  """
  def typical_duration_ms(sample \\ @duration_sample) do
    from(c in Check,
      where: c.status == "done" and not is_nil(c.duration_ms),
      order_by: [desc: c.id],
      limit: ^sample,
      select: c.duration_ms
    )
    |> Repo.all()
    |> median()
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    case rem(length(sorted), 2) do
      1 -> Enum.at(sorted, middle)
      0 -> div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
    end
  end

  # The margin on a quoted wait. A median is by definition beaten half the
  # time, and the two directions cost differently: a review that arrives sooner
  # than promised costs nothing, while one that runs past its promise makes a
  # member reload the page to see whether anything is broken. It rides on the
  # member-facing quote only — `typical_duration_ms/0` stays the plain
  # measurement, because a statistic that quietly pads itself is no longer one.
  @wait_margin 1.2

  @doc """
  What `check` still has to wait for, in milliseconds, or nil when there is
  nothing to base it on.

  The queue runs one check at a time, so a member waits for **everything in the
  pipeline ahead of them**, and that is three separate things:

    * the check the model is chewing on right now, which is not in anybody's
      queue position — only the part of it that is left, since it may be nine
      minutes into a ten-minute run;
    * every check queued before theirs;
    * their own run.

  Counting only the queued ones (the obvious reading of "position") quotes a
  member one whole run too little whenever the model is busy, which is exactly
  when somebody is looking at the number. On top of the sum rides a
  #{trunc((@wait_margin - 1) * 100)}% margin.

  A running check is quoted only its own remaining time.
  """
  def estimated_wait_ms(%Check{status: "running"} = check) do
    case typical_duration_ms() do
      nil -> nil
      typical -> margin(remaining_of(check, typical))
    end
  end

  def estimated_wait_ms(%Check{status: "pending"} = check) do
    case typical_duration_ms() do
      nil -> nil
      typical -> margin(in_flight_remaining(typical) + (queue_position(check) + 1) * typical)
    end
  end

  def estimated_wait_ms(_finished), do: nil

  # There is deliberately no estimate for a check that does not exist yet. The
  # panel used to quote one beside the button, and a number offered before the
  # member has committed to anything is a promise with nothing behind it: it
  # rests on a median that one long document or a cold model beats easily. Once
  # a check is queued the quote comes with the queue position it is built on,
  # which is what makes it checkable.

  defp margin(ms), do: round(ms * @wait_margin)

  # What is left of the run currently occupying the model. Zero when nothing is
  # running, and never negative: a run past its typical duration is simply
  # "about to finish" as far as the person behind it is concerned.
  defp in_flight_remaining(typical) do
    from(c in Check, where: c.status == "running", order_by: [asc: c.id], limit: 1)
    |> Repo.one()
    |> case do
      nil -> 0
      running -> remaining_of(running, typical)
    end
  end

  defp remaining_of(%Check{started_at: nil}, typical), do: typical

  defp remaining_of(%Check{started_at: started_at}, typical) do
    elapsed = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
    max(typical - elapsed, 0)
  end

  @doc "The due pending checks the next drain would pick up, oldest first."
  def list_due(opts \\ []) do
    now = DateTime.utc_now(:second)

    from(c in Check,
      where:
        c.status == "pending" and
          (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now),
      # By id, for the same reason `queue_position/1` counts by id: it is the
      # only ordering that is both creation order and unique.
      order_by: [asc: c.id],
      limit: ^Keyword.get(opts, :limit, @batch)
    )
    |> Repo.all()
  end

  ## Draining

  @doc """
  Runs every due check. `opts`: `analyze:` injects the analysis function
  (tests stub it; defaults to `Vutuv.References.Analyst.analyze/1`), `limit:`
  caps the batch.
  """
  def deliver_due(opts \\ []) do
    resume_stuck()
    analyze = Keyword.get(opts, :analyze, &Analyst.analyze/1)

    for check <- list_due(opts), do: process(check, analyze)

    :ok
  end

  @doc """
  Re-queues checks a crash, a reboot or a deploy left `running`. Returns the
  count reset. Called on worker boot and on each poll.

  A check is stranded when nobody has stamped its heartbeat for
  `@stale_after_seconds` — not when it has merely been running a long time,
  which on a CPU instance is normal. A row with no stamp at all was claimed by
  a release that predates the column and is stranded by definition.

  Safe to run on several nodes: the update matches on `status` and the stale
  stamp, so a check another node is actively beating is never taken from it.
  """
  def resume_stuck do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@stale_after_seconds, :second)

    {count, checks} =
      from(c in Check,
        where: c.status == "running",
        where: is_nil(c.heartbeat_at) or c.heartbeat_at < ^cutoff,
        select: c
      )
      |> Repo.update_all(
        [set: [status: "pending", updated_at: NaiveDateTime.utc_now(:second)]],
        returning: true
      )

    if count > 0 do
      Logger.info("re-queued #{count} reference check(s) stranded by a restart")
    end

    Enum.each(checks, &broadcast(%{&1 | status: "pending"}))
    count
  end

  defp process(%Check{} = check, analyze) do
    now = DateTime.utc_now(:second)

    case claim(check, "pending", "running", started_at: now, heartbeat_at: now) do
      nil ->
        :ok

      claimed ->
        broadcast(claimed)
        # Held for the whole run, including the OCR pass, which is itself a
        # minute of somebody else's process.
        with_heartbeat(claimed, fn -> run(claimed, analyze) end)
    end
  end

  # Says "somebody is still on this" for as long as the run lasts, so a check
  # interrupted by a deploy is recognised within minutes while a slow one is
  # left alone.
  #
  # The beater is deliberately **unlinked** and monitors its caller instead: a
  # linked process killed on the way out would take the worker down with it,
  # and a linked process that outlived a crashing worker would keep stamping a
  # check nobody is running — the exact failure this exists to prevent. So it
  # stops on `:stop`, and also when the process that started it goes away.
  defp with_heartbeat(%Check{id: id}, fun) do
    parent = self()
    beater = spawn(fn -> heartbeat_loop(id, Process.monitor(parent)) end)

    try do
      fun.()
    after
      send(beater, :stop)
    end
  end

  defp heartbeat_loop(check_id, monitor_ref) do
    receive do
      :stop -> :ok
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> :ok
    after
      @heartbeat_interval_ms ->
        if beat(check_id) > 0, do: heartbeat_loop(check_id, monitor_ref), else: :ok
    end
  end

  # Only a check still `running` is stamped: once it finished (or another node
  # took it over) there is nothing to keep alive, and the beater stops.
  defp beat(check_id) do
    {count, _} =
      from(c in Check, where: c.id == ^check_id and c.status == "running")
      |> Repo.update_all(set: [heartbeat_at: DateTime.utc_now(:second)])

    count
  end

  defp run(%Check{} = check, analyze) do
    case Repo.get(JobReference, check.job_reference_id) do
      nil -> cancel(check)
      reference -> analyze_and_apply(check, reference, analyze)
    end
  end

  # The text is read *inside* the job, not at upload time: OCR takes 20-70
  # seconds, which is a background wait with an hourglass, not something to
  # hold a form submit open for. Whatever it produces is stored on the entry,
  # so the member can proof-read it afterwards and the next check reuses it.
  defp analyze_and_apply(check, reference, analyze) do
    case ensure_text(check, reference) do
      {:ok, reference} -> run_analysis(check, reference, analyze)
      {:error, {class, reason}} -> retry_for(check, class, reason)
    end
  end

  defp ensure_text(check, reference) do
    if has_text?(reference), do: {:ok, reference}, else: extract_text(check, reference)
  end

  defp extract_text(check, reference) do
    case JobReferenceDocument.original_path(reference.id) do
      nil ->
        {:error, {:analysis, :no_body}}

      path ->
        path |> TextExtraction.extract() |> store_text(check, reference)
    end
  end

  defp store_text({:ok, text, source}, check, reference) do
    reference =
      reference
      |> Ecto.Changeset.change(body: text, body_source: source)
      |> Repo.update!()

    # The check was queued against an empty body, so its fingerprint names
    # nothing. Re-bind it to the text actually analysed, or the result would
    # report itself outdated the moment it appears.
    from(c in Check, where: c.id == ^check.id)
    |> Repo.update_all(set: [body_fingerprint: fingerprint(text)])

    {:ok, reference}
  end

  # `:unavailable` is the reader being down, which is our problem and retried
  # without spending an attempt. Anything else is this document.
  defp store_text({:error, :unavailable}, _check, _reference),
    do: {:error, {:service, :ocr_unavailable}}

  defp store_text({:error, reason}, _check, _reference), do: {:error, {:analysis, reason}}

  defp retry_for(check, :service, reason), do: service_retry(check, reason)
  defp retry_for(check, :analysis, reason), do: analysis_retry(check, reason)

  defp run_analysis(check, reference, analyze) do
    case analyze.(reference.body) do
      {:ok, result} -> finish(check, reference, result)
      {:error, {:service, reason}} -> service_retry(check, reason)
      {:error, {:analysis, reason}} -> analysis_retry(check, reason)
    end
  rescue
    error ->
      Logger.error("reference check crashed: #{inspect(error)}")
      analysis_retry(check, :crashed)
  end

  defp finish(check, reference, result) do
    now = DateTime.utc_now(:second)

    check
    |> claim("running", "done",
      # Re-read the fingerprint from the row as it is *now*: the member may
      # have edited the Zeugnis while the model was working, and the result
      # describes the text it was given, not the one on screen. Storing the
      # analysed text's fingerprint is what makes that visible as "outdated"
      # instead of passing a stale reading off as current.
      body_fingerprint: check.body_fingerprint || fingerprint(reference.body),
      result_markdown: result.markdown,
      # Read the grade out of the answer once, here, and store it: every list
      # row and result page then shows the verdict this run reached, and a
      # later change to the parser cannot restate a grade a member has already
      # acted on.
      grade_span: Check.parse_grade_span(result.markdown),
      model: result.model,
      skill_version: result.skill_version,
      skill_sha256: result.skill_sha256,
      prompt_tokens: result.prompt_tokens,
      output_tokens: result.output_tokens,
      duration_ms: result.duration_ms,
      last_error: nil,
      finished_at: now
    )
    |> log_reviewed(result)
    |> notify_member(reference)
    |> broadcast_result()
  end

  # The member was told they could close the page, so the result has to find
  # them: a notification for the open page and the badge, an email for the
  # member who took us up on it and logged out. Best-effort inside
  # `Vutuv.Activity`, and only on a real transition.
  defp notify_member(nil, _reference), do: nil

  defp notify_member(%Check{} = check, reference) do
    Activity.notify_reference_check(check, reference)
    check
  end

  # A machine read the member's Zeugnis, so it belongs in the account log the
  # same way a sign-in does. Only on a real transition (a lost race answers
  # nil), and it names the model rather than the verdict: which model read your
  # document is a fact worth keeping for a year, what grade it gave is not.
  defp log_reviewed(nil, _result), do: nil

  defp log_reviewed(%Check{} = check, result) do
    details = if is_binary(result.model), do: %{model: result.model}, else: %{}
    AccountEvents.record(check.user_id, "job_reference_reviewed", details: details)
    check
  end

  # The model is down. Not this Zeugnis's fault, so the attempt is not counted
  # against the cap — only delayed.
  defp service_retry(check, reason) do
    delay = @service_retry_seconds

    Logger.info("reference check service error (#{inspect(reason)}); retrying in #{delay}s")

    check
    |> claim("running", "pending",
      next_attempt_at: DateTime.add(DateTime.utc_now(:second), delay, :second),
      last_error: error_label(reason)
    )
    |> broadcast_result()
  end

  # This run cannot be trusted. Counted, because retrying an unchanged
  # misconfiguration forever would occupy the queue and tell nobody.
  defp analysis_retry(check, reason) do
    attempts = check.attempts + 1

    if attempts >= @max_attempts do
      Logger.error("reference check giving up after #{attempts} attempts: #{inspect(reason)}")

      check
      |> claim("running", "failed",
        attempts: attempts,
        last_error: error_label(reason),
        finished_at: DateTime.utc_now(:second)
      )
      |> broadcast_result()
    else
      delay = Enum.at(@analysis_backoff, min(check.attempts, length(@analysis_backoff) - 1))

      check
      |> claim("running", "pending",
        attempts: attempts,
        next_attempt_at: DateTime.add(DateTime.utc_now(:second), delay, :second),
        last_error: error_label(reason)
      )
      |> broadcast_result()
    end
  end

  # The Zeugnis disappeared while the check was in flight.
  defp cancel(check) do
    check
    |> claim("running", "canceled", finished_at: DateTime.utc_now(:second))
    |> broadcast_result()
  end

  # Moves one check between statuses, claiming the transition for this process:
  # the `where` on the current status means two drains racing the same row
  # produce exactly one winner, and the loser gets nil.
  defp claim(%Check{id: id}, from_status, to_status, extra) do
    now = NaiveDateTime.utc_now(:second)
    set = Keyword.merge([status: to_status, updated_at: now], extra)

    from(c in Check, where: c.id == ^id and c.status == ^from_status, select: c)
    |> Repo.update_all([set: set], returning: true)
    |> case do
      {1, [check]} ->
        # Leaving the waiting set moves everyone behind up one, and none of
        # them hears about it on their own topic. Announced only on a real
        # transition (the update matched), never on a lost race.
        if from_status == "pending", do: broadcast_queue_changed()
        check

      _none ->
        nil
    end
  end

  defp broadcast_result(nil), do: :ok
  defp broadcast_result(%Check{} = check), do: broadcast(check)

  # Tells the member's own topic that this check moved. The LiveView listens
  # there anyway for the shell badges, so this needs no new subscription.
  defp broadcast(%Check{} = check) do
    Activity.broadcast(check.user_id, {:reference_check, check})
    :ok
  end

  # Operator-facing, and deliberately never carries Zeugnis text: this string
  # reaches log lines and an admin screen, and the member's document must not
  # travel with it.
  defp error_label(reason), do: reason |> inspect() |> String.slice(0, 255)
end
