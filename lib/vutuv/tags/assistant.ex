defmodule Vutuv.Tags.Assistant do
  @moduledoc """
  The assisted pass over the tag catalog (issue #1338): propose consolidations
  for a human to approve, never apply one.

  Four rules decide whether this is useful or destructive, and they are the
  reason the module is shaped the way it is.

  **1. Candidates are generated cheaply and deterministically, not by a model.**
  Three rules over the *names*, each cheap enough to run over the whole catalog
  in one query plus a fold:

    * `same_key` — the names agree once case and separators are folded away, so
      `rubyonrails` meets `Ruby on Rails` and `OpenSource` meets `open source`.
    * `acronym` — a multi-word name's initials are another tag's whole name, so
      `ROR` meets `Ruby on Rails` and `CRM` meets `Customer Relationship
      Management`.
    * `token` — a short name is one whole word of a longer one, so `rails` meets
      `Ruby on Rails`. This is the noisy rule and the reason a judge exists: it
      also produces `Ruby` / `Ruby on Rails`, which must never be merged.

  There is deliberately **no edit distance and no trigram similarity**, although
  `pg_trgm` is installed and would be the obvious reach. Both are typo catchers,
  typos are out of scope for this issue, and a near-miss pair is exactly where a
  wrong merge does the most damage.

  **2. It proposes, it never applies.** The output is a `Vutuv.Tags.MergeCandidate`
  row with a suggested canonical, a kind and a one-line reason. A human approves
  it on `/admin/tag_merges`.

  **3. The dangerous cases are excluded by rule, not by prompt.** Before a pair
  can reach the model it must survive `Vutuv.Tags.Merge.preview/2`'s own refusals
  — an honor tag, an alternative name, a pair already called distinct, and above
  all a pair whose names differ only in characters the slugifier deletes, which
  is the `c` / `c++` / `c#` / `µc` bucket from #1337. Asking a model to be
  careful about those is not a guardrail.

  **4. It runs through the existing local-model seam** (`Vutuv.Ollama`, shared
  with image moderation and the Arbeitszeugnis analysis) as an admin-triggered
  batch, never a runtime path, and it is gated by `:tag_merge_assist`. With the
  flag off, or Ollama unreachable, `scan/1` still fills the queue and a human
  administers it by hand — which is what an air-gapped installation does.
  """

  require Logger

  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.Tags.Merge
  alias Vutuv.Tags.MergeCandidate
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagDistinction
  alias Vutuv.Tags.UserTag

  # A name shorter than this is not a word anyone shares a topic under, and as a
  # `token` candidate it would pair half the catalog with the other half.
  @min_token_length 3

  # How many proposals one scan may leave behind. The queue is meant to be read,
  # and what is dropped is logged rather than silently trimmed.
  @default_cap 500

  @req_options_key :tag_merge_assist_req_options

  @doc """
  Runs the pass: generate candidates, judge as many as the model will, and write
  the queue. Returns `%{generated:, refused:, judged:, written:, dropped:}`.

  `opts` takes `:cap` (how many proposals to keep, default #{@default_cap}) and
  `:judge` (false to skip the model entirely, which is also what a disabled
  `:tag_merge_assist` or an unreachable Ollama amounts to).
  """
  def scan(opts \\ []) do
    cap = Keyword.get(opts, :cap, @default_cap)
    tags = catalog()
    pairs = generate(tags)

    allowed = refuse(pairs)
    refused = length(pairs) - length(allowed)

    # Pairs already waiting are not re-proposed, and above all they do not spend
    # this run's budget: the cap is what one pass may ADD. Otherwise the queue
    # would fill with the same top 500 every time and the long tail — which is
    # where the `token` rule lives — could never be reached at all.
    queued = queued_pairs()

    fresh =
      Enum.reject(allowed, fn {a, b, _generator} ->
        MapSet.member?(queued, MergeCandidate.ordered(a.id, b.id))
      end)

    ranked = rank(fresh, member_counts())
    kept = Enum.take(ranked, cap)
    dropped = length(ranked) - length(kept)

    if dropped > 0 do
      Logger.info(
        "tag merge assistant: #{dropped} candidate pairs past the cap of #{cap} were not written"
      )
    end

    judge? = Keyword.get(opts, :judge, enabled?())
    results = kept |> Enum.map(&write(&1, judge?)) |> Enum.reject(&is_nil/1)

    %{
      generated: length(pairs),
      refused: refused,
      written: Enum.count(results, &match?({:ok, _}, &1)),
      judged: Enum.count(results, fn r -> match?({:ok, %{judged_at: %{}}}, r) end),
      dropped: dropped
    }
  end

  @doc "Whether the model half of the pass is switched on for this installation."
  def enabled?, do: Application.get_env(:vutuv, :tag_merge_assist, true)

  @doc """
  The queue, most members affected first — the consequential merges get looked
  at before the trivia.
  """
  def queue(limit \\ 100) do
    Repo.all(
      from(c in MergeCandidate,
        order_by: [desc: c.members_affected, asc: c.id],
        limit: ^limit,
        preload: [:tag_a, :tag_b, :suggested_canonical]
      )
    )
  end

  @doc "How many proposals are waiting."
  def queue_size, do: Repo.aggregate(MergeCandidate, :count)

  @doc "One proposal, with its tags loaded."
  def get_candidate(id) do
    Vutuv.UUIDv7.with_cast(id, fn uuid ->
      Repo.one(
        from(c in MergeCandidate,
          where: c.id == ^uuid,
          preload: [:tag_a, :tag_b, :suggested_canonical]
        )
      )
    end)
  end

  @doc """
  Takes a proposal off the queue. The decision itself (a merge, a distinction)
  is the caller's; this only clears the row so it is not proposed again.
  """
  def drop(%MergeCandidate{} = candidate), do: Repo.delete(candidate)

  @doc """
  Takes this pair off the queue however it was decided — merged by hand, called
  distinct by hand — so a decided pair is never proposed a second time.
  """
  def drop_pair(%Tag{} = a, %Tag{} = b) do
    {tag_a_id, tag_b_id} = MergeCandidate.ordered(a.id, b.id)

    Repo.delete_all(
      from(c in MergeCandidate, where: c.tag_a_id == ^tag_a_id and c.tag_b_id == ^tag_b_id)
    )
  end

  @doc "Empties the queue without deciding anything."
  def clear, do: Repo.delete_all(MergeCandidate)

  # --- generating -----------------------------------------------------------

  # Every tag that can take part: a real topic, not an honor badge.
  defp catalog do
    Repo.all(from(t in Tag.not_merged(), where: not t.honor?, select: %{id: t.id, name: t.name}))
  end

  @doc """
  The candidate pairs the three rules find in `tags` (a list of `%{id:, name:}`).

  Public because it is the part worth testing on its own: given a catalog, these
  pairs and no others.
  """
  def generate(tags) do
    by_key = Enum.group_by(tags, &fold(&1.name))

    [same_key(by_key), acronyms(tags, by_key), tokens(tags, by_key)]
    |> Enum.concat()
    |> Enum.uniq_by(fn {a, b, _} -> Enum.sort([a.id, b.id]) end)
  end

  # Two spellings that fold to the same thing.
  defp same_key(by_key) do
    for {_key, [_, _ | _] = group} <- by_key,
        [a, b] <- pairs(group),
        do: {a, b, "same_key"}
  end

  # A multi-word name's initials as somebody else's whole name.
  defp acronyms(tags, by_key) do
    for tag <- tags,
        words = words(tag.name),
        length(words) > 1,
        initials = Enum.map_join(words, &String.first/1),
        String.length(initials) > 1,
        other <- Map.get(by_key, fold(initials), []),
        other.id != tag.id,
        do: {tag, other, "acronym"}
  end

  # A short name that is one whole word of a longer one. The rule that needs a
  # judge: `rails` belongs to `Ruby on Rails`, `Ruby` does not.
  defp tokens(tags, by_key) do
    for tag <- tags,
        words = words(tag.name),
        length(words) > 1,
        word <- words,
        String.length(word) >= @min_token_length,
        other <- Map.get(by_key, fold(word), []),
        other.id != tag.id,
        do: {tag, other, "token"}
  end

  # Every unordered pair in a group, each once. The drop walks the **sorted**
  # list, not the original: dropping from the unsorted one pairs a tag with
  # itself as soon as the two orders differ.
  defp pairs(group) do
    sorted = Enum.sort_by(group, & &1.id)

    sorted
    |> Enum.with_index()
    |> Enum.flat_map(fn {a, i} -> sorted |> Enum.drop(i + 1) |> Enum.map(&[a, &1]) end)
  end

  defp words(name), do: name |> String.split(~r/[\s_-]+/u, trim: true)

  # Case and separators folded away; punctuation deliberately kept, so `c` and
  # `c++` never share a key and the bucket from #1337 is not even generated.
  defp fold(name), do: name |> String.downcase() |> String.replace(~r/[\s_-]+/u, "")

  # --- refusing -------------------------------------------------------------

  # A proposal must be something a merge would actually accept, so the queue can
  # never offer a pair that is refused on approval. Two of `Vutuv.Tags.Merge`'s
  # four refusals are already spent by the catalog query (an honor tag and an
  # alternative name are not in it); the other two are applied here in bulk.
  #
  # In bulk, and deliberately **not** by calling `Merge.preview/2` per pair: the
  # preview counts rows in seven tables, and the real catalog generates about
  # 5,000 pairs, which would be some 75,000 queries to answer a question that
  # needs one query and a string comparison. The preview belongs on the review
  # screen, where it is asked once about the pair an admin is looking at.
  defp refuse(pairs) do
    distinct =
      Repo.all(from(d in TagDistinction, select: {d.tag_a_id, d.tag_b_id})) |> MapSet.new()

    Enum.reject(pairs, fn {a, b, _generator} ->
      MapSet.member?(distinct, TagDistinction.ordered(a.id, b.id)) or
        Merge.punctuation_only_difference?(a.name, b.name)
    end)
  end

  # The pairs already waiting, read once per run.
  defp queued_pairs do
    Repo.all(from(c in MergeCandidate, select: {c.tag_a_id, c.tag_b_id})) |> MapSet.new()
  end

  # --- ranking --------------------------------------------------------------

  # How many profiles a merge would touch, in one query for the whole catalog.
  defp member_counts do
    Repo.all(from(ut in UserTag, group_by: ut.tag_id, select: {ut.tag_id, count(ut.id)}))
    |> Map.new()
  end

  # Rule first, then how many members the merge would touch.
  #
  # Members alone is the ordering the issue asks for, and measured against the
  # real catalog it puts the **worst** proposals on top: the biggest tags are
  # the ones every specialization shares a word with, so `Linux` arrives with
  # twenty rows like `embedded linux` and `arch linux`, none of them a merge,
  # and the reviewer meets them before the obvious `javascript` / `java script`.
  # So the rule that found a pair ranks above its size: two spellings of one
  # string first, then initials, then the merely-shares-a-word bucket.
  @rule_order %{"same_key" => 0, "acronym" => 1, "token" => 2}

  defp rank(pairs, counts) do
    pairs
    |> Enum.map(fn {a, b, generator} ->
      members = Map.get(counts, a.id, 0) + Map.get(counts, b.id, 0)
      {a, b, generator, members}
    end)
    |> Enum.sort_by(fn {_, _, generator, members} ->
      {Map.get(@rule_order, generator, 9), -members}
    end)
  end

  # --- writing + judging ----------------------------------------------------

  defp write({a, b, generator, members}, judge?) do
    {tag_a_id, tag_b_id} = MergeCandidate.ordered(a.id, b.id)
    verdict = if judge?, do: judge(a, b, generator), else: nil

    # A `token` pair only reaches the queue when the model has said it is one
    # topic. That rule pairs `Linux` with every specialization somebody named
    # after it, and an unjudged row of that kind is not a proposal, it is a
    # chore — measured on the real catalog it is four fifths of everything the
    # generators find. The other two rules stand on their own: two spellings of
    # one string are worth a human's glance with or without a verdict.
    if generator == "token" and is_nil(verdict) do
      nil
    else
      attrs =
        %{
          tag_a_id: tag_a_id,
          tag_b_id: tag_b_id,
          generator: generator,
          members_affected: members
        }
        |> Map.merge(verdict || %{})

      %MergeCandidate{}
      |> MergeCandidate.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:generator, :members_affected, :updated_at]},
        conflict_target: [:tag_a_id, :tag_b_id]
      )
    end
  end

  @doc """
  Asks the local model whether two names are one topic, and which should survive.

  Answers a map of changeset attributes, or `nil` when the model is off,
  unreachable or says these are different topics — in which case the pair stays
  in the queue unjudged rather than being decided by silence.
  """
  def judge(a, b, generator) do
    with true <- enabled?(),
         {:ok, %{"message" => %{"content" => content}}} <- ask(a, b, generator),
         {:ok, verdict} <- Jason.decode(content),
         true <- verdict["same_topic"] == true do
      canonical = if verdict["canonical"] == "b", do: b, else: a

      %{
        suggested_canonical_id: canonical.id,
        kind: kind(verdict["kind"]),
        reason: verdict["reason"] && String.slice(to_string(verdict["reason"]), 0, 1_000),
        judged_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }
    else
      _ -> nil
    end
  end

  defp kind(kind) when kind in ["alias", "abbreviation", "former"], do: kind
  defp kind(_), do: "alias"

  defp ask(a, b, generator) do
    Vutuv.Ollama.post(
      "/api/chat",
      %{
        model: model(),
        stream: false,
        think: false,
        format: schema(),
        options: %{temperature: 0},
        messages: [
          %{role: "system", content: system_prompt()},
          %{
            role: "user",
            content: """
            Tag A: #{a.name}
            Tag B: #{b.name}
            Found by rule: #{generator}
            """
          }
        ]
      },
      timeout: timeout(),
      req_options_key: @req_options_key
    )
  end

  # The model is asked one narrow question and told to refuse when unsure,
  # because the cost of the two answers is not the same: a missed duplicate
  # stays a duplicate, a wrong merge moves other people's rows.
  defp system_prompt do
    """
    You decide whether two tag names on a professional network name the SAME topic.

    Say they are the same only when a reader would expect one page for both, like
    "Ruby on Rails" and "rails", or "Customer Relationship Management" and "CRM".

    Say they are DIFFERENT whenever one is broader than the other or they are
    merely related: "Ruby" (the language) and "Ruby on Rails" (the framework) are
    different, so are "Java" and "JavaScript", "Design" and "Interior Design".

    If you are not sure, answer that they are different.

    When they are the same, canonical is the name most people would search for:
    the established full spelling rather than an abbreviation or a run-together
    form. kind describes the OTHER name: "abbreviation" for a short form,
    otherwise "alias". Give one short sentence as the reason, in English.
    """
  end

  # Ollama structured output: the model may only answer this shape.
  defp schema do
    %{
      type: "object",
      properties: %{
        same_topic: %{type: "boolean"},
        canonical: %{type: "string", enum: ["a", "b"]},
        kind: %{type: "string", enum: ["alias", "abbreviation"]},
        reason: %{type: "string"}
      },
      required: ["same_topic", "canonical", "kind", "reason"]
    }
  end

  defp model do
    Application.get_env(:vutuv, :tag_merge_assist_model, "qwen3.5:9b")
  end

  defp timeout, do: Application.get_env(:vutuv, :tag_merge_assist_timeout, 60_000)
end
