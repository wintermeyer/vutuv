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
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Languages
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
  # detection is nobody waiting (`Vutuv.Translations.Worker`).
  @detect_batch @batch
  # The one-off backfill run has no reader behind it and its own process, so
  # it only pays one query per round instead of one per couple of rows.
  @detect_all_batch 25
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
  batch.

  Every outcome stamps `language_checked_at`, including the one where the text
  could not be placed at all — that stamp is the scheduler's clock, not a
  claim that a language was found. Without it an unplaceable row would be due
  again on the very next round and hold the front of every batch forever (the
  `refresh_counts` starvation lesson). A service failure is the one outcome
  that stamps nothing: the row is not the problem.
  """
  def detect_due(opts \\ []) do
    if Keyword.get(opts, :force, false) or enabled?() do
      detect = Keyword.get(opts, :detect, &Detector.detect/1)

      opts
      |> Keyword.get(:limit, @detect_batch)
      |> due_for_detection()
      |> Enum.reduce_while({:ok, 0}, &detect_subject(&1, &2, detect))
    else
      {:ok, 0}
    end
  end

  defp detect_subject(subject, {:ok, checked}, detect) do
    case detect.(subject) do
      {:ok, language} -> {:cont, {:ok, checked + stamp_language(subject, language)}}
      {:error, {:content, _reason}} -> {:cont, {:ok, checked + stamp_language(subject, nil)}}
      {:error, {:service, _reason}} -> {:halt, {:paused, checked}}
    end
  end

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
  def source_text(%Post{body: body}), do: body
  def source_text(%RemotePost{content_text: text}), do: text || ""
  def source_text(%Note{content_text: text}), do: text || ""

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
  """
  def request(subject, target_language) do
    cond do
      not enabled?() ->
        :disabled

      translation = fresh_translation(subject, target_language) ->
        {:cached, translation}

      true ->
        {:queued, job} = queue(subject, target_language)
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
  def queue(subject, target_language) do
    if enabled?() do
      {:queued, open_job(subject, target_language) || insert_job!(subject, target_language)}
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

  defp insert_job!(subject, target_language) do
    %TranslationJob{target_language: target_language}
    |> struct!(subject_attrs(subject))
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: conflict_target(subject, " AND status IN ('pending', 'running')")
    )

    # Re-read instead of trusting the returned struct: on a lost race the
    # insert did nothing and the struct's id names no row.
    open_job(subject, target_language)
  end

  ## Draining the queue (called by Vutuv.Translations.Worker)

  @doc """
  Translates every due job. A no-op while `:translate_posts` is off (jobs
  stay pending). `opts`: `translate:` injects the per-subject translation
  function (tests stub it; defaults to `Translator.translate/2`), `force:`
  runs even with the flag off, `limit:` caps the batch.
  """
  def deliver_due(opts \\ []) do
    if Keyword.get(opts, :force, false) or enabled?() do
      resume_stuck()
      translate = Keyword.get(opts, :translate, &Translator.translate/2)
      for job <- list_due(opts), do: process_job(job, translate)
    end

    :ok
  end

  @doc "The due pending jobs the next drain would pick up, oldest first."
  def list_due(opts \\ []) do
    now = DateTime.utc_now(:second)

    from(j in TranslationJob,
      where:
        j.status == "pending" and
          (is_nil(j.next_attempt_at) or j.next_attempt_at <= ^now),
      order_by: [asc: j.inserted_at],
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
