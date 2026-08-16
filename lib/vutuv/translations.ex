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

  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Translations.Translation
  alias Vutuv.Translations.TranslationJob

  @type subject :: %Post{} | %RemotePost{} | %Note{}

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
    if translation = Repo.one(translation_query(subject, target_language)) do
      if translation.source_sha256 == source_sha256(subject), do: translation
    end
  end

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
  What a reader's translate request comes down to: the cached row when it is
  still fresh (`{:cached, translation}`), otherwise a queued job
  (`{:queued, job}` — deduped, so a second click lands on the same open row).
  """
  def request(subject, target_language) do
    if translation = fresh_translation(subject, target_language) do
      {:cached, translation}
    else
      {:queued, open_job(subject, target_language) || insert_job!(subject, target_language)}
    end
  end

  @doc "The open (pending or running) job for `subject` + target, if any."
  def open_job(subject, target_language) do
    from(j in job_query(subject, target_language),
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

  defp translation_query(subject, target_language) do
    [{column, id}] = subject_attrs(subject)

    from(t in Translation,
      where: field(t, ^column) == ^id and t.target_language == ^target_language
    )
  end

  defp job_query(subject, target_language) do
    [{column, id}] = subject_attrs(subject)

    from(j in TranslationJob,
      where: field(j, ^column) == ^id and j.target_language == ^target_language
    )
  end

  defp presence(nil), do: nil
  defp presence(value), do: if(String.trim(value) == "", do: nil, else: value)
end
