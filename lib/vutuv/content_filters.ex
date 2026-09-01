defmodule Vutuv.ContentFilters do
  @moduledoc """
  A member's private content filters (issue #940): the owner-only deny list that
  hides matching posts from their own feed. Each entry mutes a **tag** or a
  **keyword/phrase** (with `*` wildcards), optionally only where it is said by
  certain **accounts**; see `Vutuv.ContentFilters.ContentFilter`.

  The feed compiles a member's whole list once per page (`compile_for/1`) and
  asks `filtered/2` per post which filter, if any, hides it — so the post
  collapses to a "Show anyway" placeholder rather than vanishing (a silently
  shorter feed confuses and breaks reply threads). It never filters the member's
  own posts; that guard sits at the call site.

  Nothing here is public: the list is the member's alone, one-directional, never
  notifies, never reaches the agent formats, and rides along in the GDPR export.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.ContentFilters.ContentFilter
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.UUIDv7

  # A member cannot mute the whole world: cap the list so a runaway import (or a
  # bored user) can't turn every feed page into a compile of hundreds of regexes.
  @max_filters 200

  @doc "The maximum number of filters one member may keep."
  def max_filters, do: @max_filters

  @doc "The member's filters, newest first. `[]` for a logged-out visitor."
  def list_for_user(nil), do: []

  def list_for_user(%User{id: user_id}) do
    Repo.all(from(f in ContentFilter, where: f.user_id == ^user_id, order_by: [desc: f.id]))
  end

  @doc "How many filters the member already keeps (for the cap check + UI)."
  def count_for_user(%User{id: user_id}) do
    Repo.aggregate(from(f in ContentFilter, where: f.user_id == ^user_id), :count)
  end

  @doc "A blank changeset for the add form."
  def change_filter(attrs \\ %{}), do: ContentFilter.changeset(%ContentFilter{}, attrs)

  @doc """
  Add a filter to `user`'s list. `user_id` is set here, never cast, so a request
  can only add to its own list. Refuses past the cap.
  """
  def create_filter(%User{} = user, attrs) do
    if count_for_user(user) >= @max_filters do
      {:error, :too_many}
    else
      %ContentFilter{user_id: user.id}
      |> ContentFilter.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Remove one of `user`'s filters. Scoped to the owner, so it can only drop their
  own — and a malformed id is a miss rather than a crash: the id comes off the
  URL (`DELETE /settings/filters/:id`), so an edited one raised
  `Ecto.Query.CastError` and 500ed the member's own settings page.
  """
  def delete_filter(%User{id: user_id}, id) do
    case UUIDv7.cast_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        {count, _} =
          Repo.delete_all(
            from(f in ContentFilter, where: f.id == ^uuid and f.user_id == ^user_id)
          )

        if count == 1, do: :ok, else: {:error, :not_found}
    end
  end

  @doc """
  Compile `user`'s list into the shape the matchers below read:

      %{
        tags: [%{pattern: "Crypto", tag: "crypto", re: ~r/\\bcrypto\\b/iu, account: nil}, ...],
        keywords: [%{pattern: "crypto*", re: ~r/.../iu, account: ~r/.../iu}, ...]
      }

  Each entry keeps the original `pattern` (the placeholder names it), the regex
  it matches with, and `account` — the compiled scope, or `nil` for a rule that
  reads every account. A tag entry additionally carries its normalized
  (downcased) `tag`, which a post tag is compared against by slug or by name,
  and a whole-word `re` for the surfaces that have only text: muting `art` must
  not swallow "particular", and a leading `#` is a word boundary, so the same
  regex catches the hashtag form.

  Everything is compiled **here**, once per page, so no matcher builds a regex
  per post. Returns the empty shape for a member with no filters (or a
  logged-out visitor), so the caller can skip the work.
  """
  def compile_for(user) do
    user |> list_for_user() |> compile()
  end

  @doc """
  The same compiled shape for a single rule being typed — what the feed's filter
  band previews before anything is saved.

  Here rather than at the call site so the preview cannot drift from the list:
  the band used to assemble the map by hand, which is one more place every
  change to the shape has to be remembered. Substring rather than whole-word,
  which is what the band writes when the rule is saved.
  """
  def compile_draft(pattern, account) do
    compile([
      %ContentFilter{kind: :keyword, pattern: pattern, account: account, whole_word: false}
    ])
  end

  @doc """
  Compile a list of `%ContentFilter{}` rows into the matcher shape above.

  Public so a caller holding rows it did not read from this module — a test, a
  preview — compiles them exactly as the feed does.
  """
  def compile(filters) do
    tags =
      for %{kind: :tag} = filter <- filters,
          normalized = String.downcase(filter.pattern),
          re = compile_pattern(normalized, true),
          re != nil do
        %{pattern: filter.pattern, tag: normalized, re: re, account: account_re(filter)}
      end

    keywords =
      for %{kind: :keyword} = filter <- filters,
          re = compile_pattern(filter.pattern, filter.whole_word),
          re != nil do
        %{pattern: filter.pattern, re: re, account: account_re(filter)}
      end

    %{tags: tags, keywords: keywords}
  end

  # nil for "every account", so the hot path is a nil check rather than a regex
  # that would match everything anyway. A scope that cannot compile is treated
  # as the whole world rather than as nothing: a rule the member wrote is meant
  # to hide something, and silently hiding too much is the failure they can see.
  defp account_re(filter) do
    if ContentFilter.every_account?(filter),
      do: nil,
      else: compile_pattern(filter.account, false)
  end

  @doc "True when the compiled set has at least one filter."
  def any?(%{tags: tags, keywords: keywords}), do: tags != [] or keywords != []

  @doc """
  The pattern of the first filter that hides `record`, or `nil` when none does.
  The caller skips the member's own posts.

  Both kinds of post are asked here, because the reader's answer is the same for
  both and the difference is only where the words sit. A vutuv `%Post{}` has
  tags of its own, so a tag filter reads those and a keyword filter reads the
  body plus the tag names. A post cached from another network (issue #1161) — or
  a remote reply — has plain text and nothing else, so **both** kinds of filter
  are applied to that text: a member who muted "crypto" as a tag did not mean
  "unless it is written somewhere without a vutuv tag on it".

  A rule that names accounts asks `Vutuv.Posts.account_names/1` who wrote this,
  and holds unless one of those names matches. An account nobody can name never
  matches a scoped rule — a rule aimed at somebody in particular must not fold a
  post from somebody unknown.

  **The words are matched first and the account second**, which is the order the
  costs are in: a regex over a body is cheap and says no for almost every post,
  while naming the account can be a query (`Posts.author/1` falls back to a
  lookup where the association was not preloaded) — and it is asked once per
  record at most, however many scoped rules the reader keeps.
  """
  def filtered(_record, %{tags: [], keywords: []}), do: nil

  def filtered(record, compiled) do
    {pattern, _names} =
      record
      |> match_groups(compiled)
      |> Enum.reduce_while({nil, nil}, fn {entries, matches?}, {_none, names} ->
        case scan(entries, matches?, record, names) do
          {nil, names} -> {:cont, {nil, names}}
          hit -> {:halt, hit}
        end
      end)

    pattern
  end

  # Which rules are asked of this record, in the order they get to answer, each
  # with the test that decides it. A vutuv post is asked about its tags first
  # and its prose second; a record that is only text (a cached remote post, a
  # remote reply) runs both kinds of rule over that text.
  defp match_groups(%Post{} = post, compiled) do
    # Both derived values are built once per post, and only for a group that has
    # rules in it: a reader with tag rules and no words must not pay for the body
    # concatenation, nor the other way round. The tags become a **set**, so each
    # rule costs one lookup — asking `Enum.any?` over the post's tags per rule
    # instead, with a `String.downcase` inside, measured 160× slower at the
    # 200-rule cap and is what this replaced.
    tag_set = if compiled.tags != [], do: post_tag_set(post)
    text = if compiled.keywords != [], do: post_text(post)

    [
      {compiled.tags, &MapSet.member?(tag_set, &1.tag)},
      {compiled.keywords, &Regex.match?(&1.re, text)}
    ]
  end

  defp match_groups(remote, compiled) do
    text = Posts.text(remote) || ""
    matches? = &Regex.match?(&1.re, text)

    [{compiled.keywords, matches?}, {compiled.tags, matches?}]
  end

  # The first rule that both matches and speaks about this account, carrying the
  # account names along so they are resolved at most once — and only once a
  # scoped rule has actually matched the words.
  defp scan([], _matches?, _record, names), do: {nil, names}

  defp scan([entry | rest], matches?, record, names) do
    with true <- matches?.(entry),
         {true, names} <- in_scope(entry, record, names) do
      {entry.pattern, names}
    else
      false -> scan(rest, matches?, record, names)
      {false, names} -> scan(rest, matches?, record, names)
    end
  end

  defp in_scope(%{account: nil}, _record, names), do: {true, names}

  defp in_scope(%{account: re}, record, names) do
    # `names || …` memoizes correctly across an empty answer: `[]` is truthy in
    # Elixir, so an account that could not be named is asked for once, not once
    # per rule.
    names = names || Posts.account_names(record)

    {Enum.any?(names, &Regex.match?(re, &1)), names}
  end

  # Everything a post's tags answer to: their names downcased and their slugs,
  # which is what a tag rule's normalized pattern is compared against.
  defp post_tag_set(post) do
    post
    |> post_tags()
    |> Enum.flat_map(&[String.downcase(&1.name), &1.slug])
    |> MapSet.new()
  end

  # Compile one keyword/phrase pattern into a case-insensitive regex.
  #
  # `*` becomes "any run of characters"; the literal segments between are
  # escaped, so no user input reaches the regex engine as syntax. With
  # `whole_word` the match is bounded by word boundaries, except on a side the
  # pattern opens with a `*` (that side is deliberately affix/substring).
  # Returns `nil` if the pattern cannot compile (defensive; the changeset
  # already caps the length).
  defp compile_pattern(pattern, whole_word) do
    body =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    left = if whole_word and not String.starts_with?(pattern, "*"), do: "\\b", else: ""
    right = if whole_word and not String.ends_with?(pattern, "*"), do: "\\b", else: ""

    case Regex.compile(left <> body <> right, "iu") do
      {:ok, re} -> re
      _ -> nil
    end
  end

  # A whole-word keyword sees the raw body plus the tag names: `\bcrypto\b`
  # matches "crypto" inside `**crypto**` or `#crypto` on its own (the `*` / `#`
  # are word boundaries), so no Markdown stripping is needed here, and matching
  # the source keeps this in the core layer.
  defp post_text(post) do
    tags = post |> post_tags() |> Enum.map_join(" ", & &1.name)
    (post.body || "") <> " " <> tags
  end

  defp post_tags(%{tags: tags}) when is_list(tags), do: tags
  defp post_tags(_post), do: []
end
