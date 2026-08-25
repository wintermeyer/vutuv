defmodule Vutuv.Translations do
  @moduledoc """
  On-demand post translations (milestone 13, the Mastodon model): the author
  declares a post's language, nothing is guessed, and a translation exists
  only because a reader asked for it — cached per subject and target
  language, never pre-computed, never federated.

  A translation's **subject** is exactly one of a local `Vutuv.Posts.Post`, a
  cached remote `Vutuv.Fediverse.RemotePost`, or a cached remote reply
  (`Vutuv.Fediverse.Note`). The nullable id triple that encodes this is
  confined to this context: outside callers hand over the subject struct and
  read `subject/1` — no ad-hoc joins on the triple (the organization
  milestone showed what leaked NULL pairs cost).

  Caching is by content hash: `source_sha256` binds a translation to the
  exact source text it rendered, so an edited post simply makes its cached
  row stale and the next request re-translates. The queue rows in
  `translation_jobs` are drained by `Vutuv.Translations.Worker` (#1458)
  through `Vutuv.Translations.Translator` (#1457).

  Local posts are additionally **pre-translated in the background**, so the
  common case is a cache hit and nobody waits for a model at all
  (`enqueue_background/1`). That sweep is deliberately the slowest thing in
  here: it never opens more than `@backlog_cap` jobs at a time, it yields to
  the fail-closed image moderation on the shared Ollama box (the worker makes
  that call), and every job it opens ranks behind every job a reader asked
  for. A reader who taps Translate on a post the sweep already queued lands on
  that same row and promotes it — one translation, and the person waiting goes
  first.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Languages
  alias Vutuv.Ollama
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Translations.Detector
  alias Vutuv.Translations.Translation
  alias Vutuv.Translations.TranslationJob
  alias Vutuv.Translations.Translator
  alias Vutuv.Translations.Worker

  @type subject :: %Post{} | %RemotePost{} | %Note{}

  # The three subject kinds, spelled once: the detection work list walks them
  # and `topic/1` guards on them.
  @subject_schemas [Post, RemotePost, Note]

  # The columns a detection reads from, across the three schemas: a change to
  # any of them re-opens the question (`reset_language_check/1`).
  @language_sources [:language, :body, :content_text]

  # Small on purpose: the Ollama box is shared with the fail-closed image
  # moderation, which keeps priority.
  @batch 2
  # The same small batch as the reader-driven queue, and for the same reason —
  # but it runs *after* that queue and never on a `nudge/0`, because a
  # detection is nobody waiting (`Vutuv.Translations.Worker`). The floor, not
  # the figure: a round takes at least this many rows and at least as many as
  # there are Ollama instances to keep busy, so no endpoint sits out a round.
  @detect_batch @batch
  # The one-off backfill run has no reader behind it and its own process, so
  # it only pays one query per round instead of one per couple of rows.
  @detect_all_batch 25
  # Rows the background sweep looks at per round, and the ceiling on how many
  # of its jobs may be outstanding. The cap IS the threshold the whole design
  # rests on: the sweep never floods the pipeline with a table's worth of work,
  # it keeps a short pile topped up, so an Ollama box that falls behind simply
  # stops receiving more and a reader's request is never more than a handful of
  # rows from the front.
  @precompute_batch 10
  @backlog_cap 20
  # How long before the sweep looks at a post it has already considered. An
  # edit re-opens it at once (the work list compares against `updated_at`), so
  # this interval exists for the other case: a translation that failed while
  # Ollama was down, which no edit will ever re-open.
  @reconsider_after_seconds 6 * 3600
  # A translation call waits up to 10 minutes (`Translator`); only a claim
  # well past that is presumed crashed and re-queued.
  @stuck_after_seconds 1800
  # After this many strikes the job ends `failed` — fail-open, the card keeps
  # showing the original. A later request simply opens a fresh job.
  @strike_cap 4
  # Service failures (Ollama down, contention stall) retry at this flat pace;
  # content failures back off exponentially from @retry_base_seconds.
  @service_retry_seconds 300
  @retry_base_seconds 60

  @doc "Whether on-demand post translation is enabled on this installation."
  def enabled?, do: Application.get_env(:vutuv, :translate_posts, false)

  @doc """
  Whether this installation also pre-translates its own posts in the
  background. On by default, but inert unless `enabled?/0` is too — an
  installation without an Ollama that can carry the model has neither.
  """
  def precompute_enabled?, do: Application.get_env(:vutuv, :precompute_translations, true)

  ## Language tags

  @doc """
  Normalizes a language tag to the lowercase primary subtag this system
  stores ("de-AT" -> "de", "EN" -> "en"). Anything that does not start with
  a 2-3 letter primary subtag — including nil — normalizes to nil, so a
  hostile or malformed inbound tag can never reach a column.
  """
  def normalize_language(value) when is_binary(value) do
    primary =
      value
      |> String.trim()
      |> String.downcase()
      |> String.split(["-", "_"], parts: 2)
      |> hd()

    if primary =~ ~r/^[a-z]{2,3}$/, do: primary
  end

  def normalize_language(_value), do: nil

  @doc """
  What may reach a `language` column: a **curated** `Vutuv.Languages` code,
  normalized to its primary subtag — anything else nil, which means
  undeclared (shown to everyone, never auto-translated, never hidden).

  Curated and not merely well-formed, because this list is exactly what a
  reader can tick on /settings/preferences: a code outside it would be hidden
  by the language filter with no chip that could ever bring it back. The one
  owner of that rule — `Vutuv.Posts.Post.cast_language/1` (the composer),
  `Vutuv.Fediverse.as2_language/1` (AS2 `contentMap`) and
  `Vutuv.Translations.Detector` (issue #1535) all read it here.
  """
  def cast_language(value) do
    normalized = normalize_language(value)
    if normalized && Languages.known?(normalized), do: normalized
  end

  ## Language detection (issue #1535)

  @doc """
  Whoever writes a subject's language — or the text it was read from — owns the
  detection clock: such a changeset clears `language_checked_at`, so the row is
  looked at again.

  Both language directions matter. A declaration that lands makes an earlier
  detection irrelevant; a declaration that is *taken back* — which is what an
  AS2 `Update` carrying no `contentMap` does to a remote post, and those are
  most of them — would otherwise leave the stamp behind on an empty column and
  drop the row out of the work list for good: undeclared forever, no filter, no
  Translate offer, never asked again. A new **text** counts too, because the
  stamp says "we looked" at words that no longer exist — the post that was one
  bare link when we looked may be a paragraph now.

  The three subject schemas call this, so no ingest or edit path has to remember
  it. What it deliberately does not do is drop a language that is already
  known: a text edit re-opens the question only for a row nobody could place.
  """
  def reset_language_check(%Ecto.Changeset{} = changeset) do
    if Enum.any?(@language_sources, &Map.has_key?(changeset.changes, &1)) do
      Ecto.Changeset.put_change(changeset, :language_checked_at, nil)
    else
      changeset
    end
  end

  @doc """
  The subjects whose language nobody knows and nobody has looked for yet, at
  most `limit`, across all three subject kinds.

  **Newest first**, against the oldest-first convention of every other sweeper
  here, and deliberately: the language of a post that is in somebody's feed
  right now is what a reader can use, while the pile from before the column
  existed is a one-off that only has to drain eventually. Nothing starves for
  it either — the inflow (remote objects arriving without a `contentMap`) is
  orders of magnitude smaller than what one poll interval can check.
  """
  def due_for_detection(limit) do
    @subject_schemas
    |> Enum.flat_map(&due_detection_rows(&1, limit))
    # Ids are UUID v7, so id order IS creation order — and lexicographic
    # order on the string form is that same order.
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.take(limit)
  end

  defp due_detection_rows(schema, limit) do
    from(r in schema,
      where: is_nil(r.language) and is_nil(r.language_checked_at),
      order_by: [desc: r.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Detects the language of every due subject, up to `limit`. Returns
  `{:ok, checked}`, or `{:paused, checked}` when Ollama stopped answering —
  the batch then stops where it is, because nothing about the next row would
  go any better.

  `opts`: `detect:` injects the per-subject detector (tests stub it; defaults
  to `Detector.detect/1`), `force:` runs with the flag off, `limit:` caps the
  batch, `max_concurrency:` how many rows are in a model at once (defaults to
  `Vutuv.Ollama.concurrency/0`).

  **Rows go to the model in parallel** up to that bound (issue #1573). One at
  a time is one Ollama instance at a time, so an installation that names a
  second GPU box in `:ollama_url` never had it take any of this work — it was
  reached only when the first box *failed*. The bound is the endpoint count
  rather than a number of our own choosing, because the endpoints are what
  there is to keep busy, and the batch is widened to it so no slot idles.
  Row claiming stays unnecessary because the parallelism is inside one
  process: a round selects its rows once and hands each to exactly one task.

  Only the model call runs in a task; the stamp is written back here, in one
  process. That keeps the writes serialised for free, and it keeps the tasks
  out of the SQL sandbox's ownership rules in tests.

  Every outcome stamps `language_checked_at`, including the one where the text
  could not be placed at all — that stamp is the scheduler's clock, not a
  claim that a language was found. Without it an unplaceable row would be due
  again on the very next round and hold the front of every batch forever (the
  `refresh_counts` starvation lesson). A service failure is the one outcome
  that stamps nothing: the row is not the problem. It also stops the batch
  where it is, which now discards whatever the sibling tasks were doing —
  their rows keep no stamp and are simply due again, so the count can come
  back one or two short of what was actually written. Both entry points use it
  as progress, never as a total.
  """
  def detect_due(opts \\ []) do
    if Keyword.get(opts, :force, false) or enabled?() do
      detect = Keyword.get(opts, :detect, &Detector.detect/1)
      concurrency = Keyword.get(opts, :max_concurrency, Ollama.concurrency())

      opts
      |> Keyword.get(:limit, max(@detect_batch, concurrency))
      |> due_for_detection()
      |> Task.async_stream(&{&1, detect_subject(detect, &1)},
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, 0}, &stamp_detection/2)
    else
      {:ok, 0}
    end
  end

  # In a task, so a raise must not take the caller down with it — the worker
  # rescues around the whole sweep, but an exiting task kills the process it
  # is linked to before any rescue is reached. A detector that blows up is a
  # service failure as far as the batch is concerned: nothing is known about
  # the text, so the row keeps no stamp and comes back.
  defp detect_subject(detect, subject) do
    detect.(subject)
  rescue
    error ->
      Logger.error("language detection crashed: #{Exception.message(error)}")
      {:error, {:service, :crashed}}
  end

  defp stamp_detection({:ok, {subject, {:ok, language}}}, {:ok, checked}),
    do: {:cont, {:ok, checked + stamp_language(subject, language)}}

  defp stamp_detection({:ok, {subject, {:error, {:content, _reason}}}}, {:ok, checked}),
    do: {:cont, {:ok, checked + stamp_language(subject, nil)}}

  defp stamp_detection({:ok, {_subject, {:error, {:service, _reason}}}}, {:ok, checked}),
    do: {:halt, {:paused, checked}}

  @doc """
  Drains the whole detection pile in one run, `@detect_all_batch` rows per
  round, and returns `{:ok | :paused | :budget, checked}`. This is the one-off
  backfill of everything written before the language column existed — a
  deliberate **run**, not a sweeper, because it is finite work and because the
  poll in `Vutuv.Translations.Worker` has to stay small enough to keep out of a
  reader's way. `Vutuv.Release.detect_post_languages/1` is the release-side
  entry point, `mix vutuv.translations.detect_languages` the local one.

  `opts`: `progress:` a one-argument function called with the running count
  after every round (defaults to a no-op — a context knows nothing about IO),
  `max_rows:` the safety ceiling, plus everything `detect_due/1` takes. Both
  entry points report the outcome through `detect_summary/1`, so the two of them
  cannot word it differently.
  """
  def detect_all(opts \\ []) do
    progress = Keyword.get(opts, :progress, fn _checked -> :ok end)
    budget = Keyword.get(opts, :max_rows, 20_000)

    opts
    |> Keyword.put_new(:limit, @detect_all_batch)
    |> detect_all_round(progress, budget, 0)
  end

  defp detect_all_round(_opts, _progress, budget, checked) when budget <= 0,
    do: {:budget, checked}

  defp detect_all_round(opts, progress, budget, checked) do
    case detect_due(Keyword.put(opts, :limit, min(opts[:limit], budget))) do
      # Nothing due: the pile is drained, which is the run's happy ending.
      {:ok, 0} ->
        {:ok, checked}

      {:ok, count} ->
        progress.(checked + count)
        detect_all_round(opts, progress, budget - count, checked + count)

      {:paused, count} ->
        {:paused, checked + count}
    end
  end

  @doc """
  One operator-facing sentence for a `detect_all/1` outcome, so the mix task and
  the release entry point cannot report the same run differently.
  """
  def detect_summary({:ok, checked}), do: "done, #{checked} checked."

  def detect_summary({:paused, checked}),
    do: "Ollama went quiet after #{checked} checked — run it again to carry on."

  def detect_summary({:budget, checked}), do: "stopped at the #{checked} row ceiling."

  # `update_all`, never a changeset: `Vutuv.Posts.Post` carries timestamps and
  # a post whose `updated_at` moves more than a minute past `inserted_at`
  # renders as "edited" — a backfill must not put that mark on hundreds of
  # posts nobody touched.
  # Writing `language: nil` for an unplaceable text is a no-op on a column the
  # work list already filtered as NULL — one shape for both outcomes.
  defp stamp_language(%schema{id: id}, language) do
    set = [language: language, language_checked_at: DateTime.utc_now(:second)]

    {count, _} = Repo.update_all(from(r in schema, where: r.id == ^id), set: set)
    count
  end

  ## The subject triple

  @doc """
  Which subject a translation or job row belongs to, as `{:post, id}`,
  `{:remote_post, id}` or `{:note, id}` — matched on the id columns, never
  on a preloaded association.
  """
  def subject(%{post_id: id}) when is_binary(id), do: {:post, id}
  def subject(%{remote_post_id: id}) when is_binary(id), do: {:remote_post, id}
  def subject(%{note_id: id}) when is_binary(id), do: {:note, id}

  @doc "Loads the subject row behind a translation or job; nil when it is gone."
  def load_subject(row) do
    case subject(row) do
      {:post, id} -> Repo.get(Post, id)
      {:remote_post, id} -> Repo.get(RemotePost, id)
      {:note, id} -> Repo.get(Note, id)
    end
  end

  @doc """
  The text a translation of this subject translates: a local post's Markdown
  body, a remote subject's plain `content_text`.
  """
  def source_text(%Post{} = post), do: Posts.text(post)
  def source_text(%RemotePost{} = post), do: Posts.text(post) || ""
  def source_text(%Note{} = note), do: Posts.text(note) || ""

  @doc "The subject's content warning, when it carries one (remote content only)."
  def source_summary(%Post{}), do: nil
  def source_summary(%RemotePost{summary: summary}), do: presence(summary)
  def source_summary(%Note{summary: summary}), do: presence(summary)

  @doc """
  The cache key over everything a translation renders (body + summary), as
  lowercase hex. Not privacy — the content is public; the hash only detects
  that the source changed under a cached row.
  """
  def source_sha256(subject) do
    :crypto.hash(:sha256, [source_text(subject), 0, source_summary(subject) || ""])
    |> Base.encode16(case: :lower)
  end

  ## The cache

  @doc """
  The cached translation of `subject` into `target_language`, but only while
  its hash still matches the subject's current text — an edited source makes
  the row stale, and a stale row answers nil (the next request re-translates).
  """
  def fresh_translation(subject, target_language) do
    if translation = Repo.one(subject_query(Translation, subject, target_language)) do
      if translation.source_sha256 == source_sha256(subject), do: translation
    end
  end

  @doc """
  `fresh_translation/2` over many subjects at once — ONE query per subject
  kind present, never one per card (the feed's translate mode renders whole
  pages). Returns `%{subject_key => %Translation{}}` for the fresh hits;
  stale and missing rows are simply absent.
  """
  def fresh_translations([], _target_language), do: %{}

  def fresh_translations(subjects, target_language) do
    by_key =
      subjects
      |> Enum.group_by(fn subject -> subject_column(subject) end, fn subject -> subject.id end)
      |> Enum.flat_map(fn {column, ids} ->
        Repo.all(
          from(t in Translation,
            where: field(t, ^column) in ^ids and t.target_language == ^target_language
          )
        )
      end)
      |> Map.new(&{subject(&1), &1})

    for subject <- subjects,
        translation = by_key[subject_key(subject)],
        translation != nil,
        translation.source_sha256 == source_sha256(subject),
        into: %{} do
      {subject_key(subject), translation}
    end
  end

  @doc ~S|The `{kind, id}` key for a SUBJECT struct — the struct-side twin of `subject/1`.|
  def subject_key(%Post{id: id}), do: {:post, id}
  def subject_key(%RemotePost{id: id}), do: {:remote_post, id}
  def subject_key(%Note{id: id}), do: {:note, id}

  @doc """
  Stores (or refreshes) the translation of `subject` into `target_language`.
  `result` carries what the model answered: `:body`, `:source_language`, and
  for remote content `:summary`; `:model` names who translated. Stamped with
  the subject's current hash.
  """
  def store_translation(subject, target_language, result) do
    now = NaiveDateTime.utc_now(:second)

    replace = [
      source_language: Map.get(result, :source_language),
      body: Map.fetch!(result, :body),
      summary: Map.get(result, :summary),
      model: Map.get(result, :model),
      source_sha256: source_sha256(subject),
      updated_at: now
    ]

    %Translation{target_language: target_language}
    |> struct!(subject_attrs(subject))
    |> struct!(replace)
    |> Repo.insert(
      on_conflict: [set: replace],
      conflict_target: conflict_target(subject, "")
    )
  end

  ## The queue

  @doc """
  What a reader's translate request comes down to: `:disabled` while the
  installation has translations off, the cached row when it is still fresh
  (`{:cached, translation}`), otherwise a queued job (`{:queued, job}` —
  deduped, so a second click lands on the same open row) with the worker
  nudged so the reader is not left waiting for the next poll.

  Reader priority by default, which also **promotes** a job the background
  sweep had already opened for this exact translation: the work already
  queued is the work the reader wanted, so they join it at the front rather
  than starting a second copy of it.
  """
  def request(subject, target_language, priority \\ TranslationJob.reader_priority()) do
    cond do
      not enabled?() ->
        :disabled

      translation = fresh_translation(subject, target_language) ->
        {:cached, translation}

      true ->
        {:queued, job} = queue(subject, target_language, priority)
        Worker.nudge()
        {:queued, job}
    end
  end

  @doc """
  Queues `subject` **without asking the cache first**, for a caller that has
  already resolved a whole page's cached translations in one query
  (`fresh_translations/2`) and knows this one missed — `request/2` would repeat
  that lookup per card. It also leaves the worker alone: a page's worth of
  subjects wants one `Worker.nudge/0` at the end, not one per card, since every
  nudge costs the worker a full drain round.
  """
  def queue(subject, target_language, priority \\ TranslationJob.reader_priority()) do
    if enabled?() do
      job =
        case open_job(subject, target_language) do
          nil -> insert_job!(subject, target_language, priority)
          job -> promote(job, priority)
        end

      {:queued, job}
    else
      :disabled
    end
  end

  @doc "The open (pending or running) job for `subject` + target, if any."
  def open_job(subject, target_language) do
    from(j in subject_query(TranslationJob, subject, target_language),
      where: j.status in ^TranslationJob.open_statuses()
    )
    |> Repo.one()
  end

  defp insert_job!(subject, target_language, priority) do
    %TranslationJob{target_language: target_language, priority: priority}
    |> struct!(subject_attrs(subject))
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: conflict_target(subject, " AND status IN ('pending', 'running')")
    )

    # Re-read instead of trusting the returned struct: on a lost race the
    # insert did nothing and the struct's id names no row.
    open_job(subject, target_language)
  end

  # One job, two askers. The comparison is what makes this safe in both
  # directions: a reader meeting the sweep's job moves it to the front, the
  # sweep meeting a reader's job leaves it exactly where it is. Only a
  # `pending` row moves — a running job is already as fast as it gets, and
  # touching it would tell `resume_stuck/0` nothing it wants to hear.
  defp promote(%TranslationJob{priority: current} = job, priority) when priority >= current,
    do: job

  defp promote(job, priority) do
    {_count, rows} =
      from(j in TranslationJob,
        where: j.id == ^job.id and j.status == "pending" and j.priority > ^priority,
        select: j
      )
      |> Repo.update_all(set: [priority: priority])

    case rows do
      [promoted] -> promoted
      [] -> job
    end
  end

  ## Pre-translating our own posts (the background sweep)

  @doc """
  Opens background jobs for the local posts that have no fresh translation
  yet, newest-considered-last, and returns how many it opened.

  Three things bound it, and all three are deliberate:

    * **The backlog cap.** While `@backlog_cap` background jobs are still
      outstanding the round does nothing at all. That is the threshold: the
      sweep tops a short pile back up, it never hands the pipeline a table's
      worth of work, and an Ollama that falls behind simply stops being given
      more.
    * **Scope.** Local posts only — our own content, in a language somebody
      declared or the detector placed, not in the freezer, with a body to
      translate. A post nobody could place a language for is not a candidate:
      there is no reader-facing Translate action on it either.
    * **The clock.** `posts.translations_enqueued_at` records that this post
      was *considered*, and it is stamped on **every** outcome — including the
      one where every target was already translated and nothing was opened.
      An unstamped no-op would be due again on the very next round and hold
      the front of the work list forever (the `refresh_counts` starvation
      lesson); `test/vutuv/translations/precompute_test.exs` calibrates
      against exactly that.

  `opts`: `force:` runs with the flags off, `limit:` rows per round,
  `backlog_cap:` the ceiling.
  """
  def enqueue_background(opts \\ []) do
    if Keyword.get(opts, :force, false) or (enabled?() and precompute_enabled?()) do
      cap = Keyword.get(opts, :backlog_cap, @backlog_cap)

      if background_backlog() < cap do
        opts |> due_for_precompute() |> Enum.map(&consider/1) |> Enum.sum()
      else
        0
      end
    else
      0
    end
  end

  @doc """
  Whether somebody is actually waiting for a translation right now.

  The gate on everything the worker does for nobody in particular. It asks
  about **reader** work rather than about an empty queue on purpose: once the
  background sweep keeps a standing backlog, "is the queue empty" is answered
  no forever, and every sweep behind that gate — language detection above all,
  which is what decides whether a post can ever be pre-translated at all —
  would switch itself off permanently.
  """
  def reader_waiting? do
    list_due(limit: 1, max_priority: TranslationJob.reader_priority()) != []
  end

  @doc """
  How many of the sweep's own jobs are still waiting or in flight. A reader's
  jobs are not counted: they are never what the cap is protecting the box
  from, and counting them would let a busy afternoon of Translate taps stand
  the sweep down for no reason.
  """
  def background_backlog do
    Repo.aggregate(
      from(j in TranslationJob,
        where:
          j.status in ^TranslationJob.open_statuses() and
            j.priority >= ^TranslationJob.background_priority()
      ),
      :count
    )
  end

  # Never considered first (NULLS FIRST, newest of those first — a post in
  # somebody's feed right now is the one a reader may ask about), then the
  # longest-unconsidered. An edit re-opens a post immediately, because its
  # `updated_at` moves past the stamp; everything else waits out
  # @reconsider_after_seconds, which is what eventually retries a translation
  # that failed while Ollama was down.
  defp due_for_precompute(opts) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@reconsider_after_seconds, :second)

    from(p in Post,
      where:
        not is_nil(p.language) and is_nil(p.frozen_at) and p.body != "" and
          (is_nil(p.translations_enqueued_at) or p.translations_enqueued_at < ^cutoff or
             p.translations_enqueued_at < p.updated_at),
      order_by: [asc_nulls_first: p.translations_enqueued_at, desc: p.id],
      limit: ^Keyword.get(opts, :limit, @precompute_batch)
    )
    |> Repo.all()
  end

  defp consider(%Post{} = post) do
    opened = Enum.count(missing_targets(post), &open_background_job(post, &1))
    stamp_precompute(post)
    opened
  end

  # Every locale a reader of this installation can be reading in, minus the
  # one the post is already written in, minus what is already translated or
  # already queued. Two small indexed lookups per target on a batch of ten
  # rows every poll — the round is nothing next to the model call it feeds.
  defp missing_targets(%Post{language: language} = post) do
    for target <- target_languages(),
        target != language,
        is_nil(fresh_translation(post, target)),
        is_nil(open_job(post, target)),
        do: target
  end

  # The installation's locales live under the ENDPOINT config, not as a
  # top-level `:vutuv` key — `Application.get_env(:vutuv, :locales)` answers
  # nil, and a read like that with a plausible default fails completely
  # silently: it translated German posts into English (right by accident, the
  # default's only entry) and English posts into nothing at all, with a green
  # suite and no log line. `Vutuv.NodeInfo` reads it the same way.
  defp target_languages do
    {:ok, config} = Application.fetch_env(:vutuv, VutuvWeb.Endpoint)

    config[:locales]
    |> List.wrap()
    |> Enum.map(&cast_language/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp open_background_job(post, target) do
    match?({:queued, _job}, queue(post, target, TranslationJob.background_priority()))
  end

  # `update_all` and this column alone: a post whose `updated_at` moves more
  # than a minute past `inserted_at` renders as "edited", and a sweep must
  # never put that mark on posts nobody touched.
  defp stamp_precompute(%Post{id: id}) do
    from(p in Post, where: p.id == ^id)
    |> Repo.update_all(set: [translations_enqueued_at: DateTime.utc_now(:second)])
  end

  ## Draining the queue (called by Vutuv.Translations.Worker)

  @doc """
  Translates every due job. A no-op while `:translate_posts` is off (jobs
  stay pending). `opts`: `translate:` injects the per-subject translation
  function (tests stub it; defaults to `Translator.translate/2`), `force:`
  runs even with the flag off, `limit:` caps the batch, `max_priority:`
  refuses anything ranked worse than that (the worker uses it to stand the
  background sweep down while image moderation needs the box).
  """
  def deliver_due(opts \\ []) do
    if Keyword.get(opts, :force, false) or enabled?() do
      resume_stuck()
      translate = Keyword.get(opts, :translate, &Translator.translate/2)
      drain(opts, translate, Keyword.get(opts, :limit, @batch))
    end

    :ok
  end

  # One job per query rather than one query per batch, and that is the whole
  # point: a translation runs for minutes, so a reader who taps Translate
  # while the sweep is mid-job would otherwise wait out every remaining row
  # of a batch that was selected before they asked. Re-asking between jobs
  # costs one indexed query and means the reader is next.
  defp drain(_opts, _translate, remaining) when remaining <= 0, do: :ok

  defp drain(opts, translate, remaining) do
    case list_due(Keyword.put(opts, :limit, 1)) do
      [] ->
        :ok

      [job] ->
        process_job(job, translate)
        drain(opts, translate, remaining - 1)
    end
  end

  @doc """
  The due pending jobs the next drain would pick up: **best priority first**,
  oldest first within a priority. `max_priority:` excludes everything ranked
  worse (defaults to including the background sweep).

  The id is the tiebreaker because `inserted_at` holds whole seconds, and two
  jobs queued in the same second are ordinary — ids are UUID v7, so id order
  is creation order at a resolution the timestamp does not have.
  """
  def list_due(opts \\ []) do
    now = DateTime.utc_now(:second)
    max_priority = Keyword.get(opts, :max_priority, TranslationJob.background_priority())

    from(j in TranslationJob,
      where:
        j.status == "pending" and j.priority <= ^max_priority and
          (is_nil(j.next_attempt_at) or j.next_attempt_at <= ^now),
      order_by: [asc: j.priority, asc: j.inserted_at, asc: j.id],
      limit: ^Keyword.get(opts, :limit, @batch)
    )
    |> Repo.all()
  end

  @doc """
  Re-queues jobs a crash left `running` for longer than any live translation
  could take. Returns the count reset. Called on worker boot and each drain.
  """
  def resume_stuck do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@stuck_after_seconds, :second)

    {count, _} =
      from(j in TranslationJob, where: j.status == "running" and j.updated_at < ^cutoff)
      |> Repo.update_all(set: [status: "pending", updated_at: NaiveDateTime.utc_now(:second)])

    count
  end

  # Every outcome stamps the job — including the branches that do no
  # translation work (subject gone, translation already stored). An unstamped
  # skip would be due again on the very next drain and hold the front of the
  # oldest-first batch forever: the `refresh_counts` starvation lesson.
  defp process_job(job, translate) do
    case claim_job(job, "pending", "running") do
      nil ->
        :ok

      job ->
        case load_subject(job) do
          # A race with the subject's deletion; the FK erases the job anyway.
          nil -> finish_failed(job, job.attempts, :subject_gone)
          subject -> translate_subject(job, subject, translate)
        end
    end
  end

  defp translate_subject(job, subject, translate) do
    if translation = fresh_translation(subject, job.target_language) do
      # Someone already stored it (a racing job, an earlier crash after the
      # store): the reader has what they asked for — done, not silently due.
      finish_done(job, translation)
    else
      case translate.(subject, job.target_language) do
        {:ok, result} ->
          {:ok, translation} = store_translation(subject, job.target_language, result)
          finish_done(job, translation)

        {:error, {class, reason}} ->
          strike(job, class, reason)
      end
    end
  end

  defp finish_done(job, translation) do
    claim_job(job, "running", "done")
    broadcast(job, {:translation_ready, translation})
    :ok
  end

  defp finish_failed(job, attempts, reason) do
    claim_job(job, "running", "failed", attempts: attempts, last_error: error_string(reason))
    broadcast(job, {:translation_failed, subject(job), job.target_language})
    :ok
  end

  # A strike is a retry until the cap, then `failed` — fail-open, the card
  # keeps showing the original. Service failures (Ollama down, a contention
  # stall on the shared box) retry at a flat patient pace; content failures
  # (the model answered junk) back off exponentially.
  defp strike(job, class, reason) do
    attempts = job.attempts + 1

    if attempts >= @strike_cap do
      Logger.warning(
        "translation failed subject=#{inspect(subject(job))} target=#{job.target_language} " <>
          "class=#{class} error=#{inspect(reason)}"
      )

      finish_failed(job, attempts, reason)
    else
      retry_at = DateTime.add(DateTime.utc_now(:second), retry_delay(class, attempts))

      claim_job(job, "running", "pending",
        attempts: attempts,
        next_attempt_at: retry_at,
        last_error: error_string(reason)
      )

      :ok
    end
  end

  defp retry_delay(:service, _attempts), do: @service_retry_seconds
  defp retry_delay(_class, attempts), do: trunc(:math.pow(2, attempts)) * @retry_base_seconds

  # Atomically moves one job between statuses, claiming the transition for
  # exactly one caller (the image_scans pattern).
  defp claim_job(%TranslationJob{id: id}, from_status, to_status, extra \\ []) do
    now = NaiveDateTime.utc_now(:second)
    set = Keyword.merge([status: to_status, updated_at: now], extra)

    {_count, rows} =
      from(j in TranslationJob, where: j.id == ^id and j.status == ^from_status, select: j)
      |> Repo.update_all(set: set)

    case rows do
      [claimed] -> claimed
      [] -> nil
    end
  end

  defp error_string(reason), do: reason |> inspect() |> String.slice(0, 255)

  ## The live swap-in (issue #1462 subscribes per shown card)

  @doc """
  The PubSub topic a subject's translations are announced on. Takes the
  subject struct or any translations row belonging to it. Messages:
  `{:translation_ready, %Translation{}}` and
  `{:translation_failed, subject_key, target_language}` (the key as
  `subject/1` returns it).
  """
  def topic(%schema{} = subject) when schema in @subject_schemas,
    do: key_topic(subject_key(subject))

  def topic(row), do: key_topic(subject(row))

  defp key_topic({kind, id}), do: "translation:#{kind}:#{id}"

  defp broadcast(row, message) do
    Phoenix.PubSub.broadcast(Vutuv.PubSub, topic(row), message)
  end

  ## Shared subject plumbing (the triple stays in here)

  defp subject_attrs(%Post{id: id}), do: [post_id: id]
  defp subject_attrs(%RemotePost{id: id}), do: [remote_post_id: id]
  defp subject_attrs(%Note{id: id}), do: [note_id: id]

  defp subject_column(%Post{}), do: :post_id
  defp subject_column(%RemotePost{}), do: :remote_post_id
  defp subject_column(%Note{}), do: :note_id

  defp conflict_target(subject, extra_where) do
    column = subject_column(subject)
    {:unsafe_fragment, "(#{column}, target_language) WHERE #{column} IS NOT NULL#{extra_where}"}
  end

  defp subject_query(schema, subject, target_language) do
    [{column, id}] = subject_attrs(subject)

    from(t in schema,
      where: field(t, ^column) == ^id and t.target_language == ^target_language
    )
  end

  defp presence(nil), do: nil
  defp presence(value), do: if(String.trim(value) == "", do: nil, else: value)
end
