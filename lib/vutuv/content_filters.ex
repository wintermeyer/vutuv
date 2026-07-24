defmodule Vutuv.ContentFilters do
  @moduledoc """
  A member's private content filters (issue #940): the owner-only deny list that
  hides matching posts from their own feed. Each entry mutes a **tag** or a
  **keyword/phrase** (with `*` wildcards); see `Vutuv.ContentFilters.ContentFilter`.

  The feed compiles a member's whole list once per page (`compile_for/1`) and
  asks `filtered_pattern/2` per post which filter, if any, hides it — so the
  post collapses to a "Show anyway" placeholder rather than vanishing (a
  silently shorter feed confuses and breaks reply threads). It never filters the
  member's own posts; that guard sits at the call site.

  Nothing here is public: the list is the member's alone, one-directional, never
  notifies, never reaches the agent formats, and rides along in the GDPR export.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.ContentFilters.ContentFilter
  alias Vutuv.Repo

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

  @doc "Remove one of `user`'s filters. Scoped to the owner, so it can only drop their own."
  def delete_filter(%User{id: user_id}, id) do
    {count, _} =
      Repo.delete_all(from(f in ContentFilter, where: f.id == ^id and f.user_id == ^user_id))

    if count == 1, do: :ok, else: {:error, :not_found}
  end

  @doc """
  Compile `user`'s list into the shape `filtered_pattern/2` matches against:

      %{tags: %{"crypto" => "crypto", ...}, keywords: [{"crypto*", ~r/.../}, ...]}

  Tags are keyed by their normalized (downcased) value so a post tag matches by
  slug or by name; each maps back to the original pattern the placeholder shows.
  Keywords carry their compiled regex. Returns the empty shape for a member with
  no filters (or a logged-out visitor), so the caller can skip the work.
  """
  def compile_for(user) do
    filters = list_for_user(user)

    tags =
      for %{kind: :tag, pattern: pattern} <- filters, into: %{} do
        {String.downcase(pattern), pattern}
      end

    keywords =
      for %{kind: :keyword, pattern: pattern, whole_word: whole_word} <- filters,
          re = compile_pattern(pattern, whole_word),
          re != nil do
        {pattern, re}
      end

    %{tags: tags, keywords: keywords}
  end

  @doc "True when the compiled set has at least one filter."
  def any?(%{tags: tags, keywords: keywords}), do: map_size(tags) > 0 or keywords != []

  @doc """
  The pattern of the first filter that hides `post`, or `nil` when none does. A
  tag filter matches the post's tags; a keyword filter matches its body and
  tags/hashtags. The caller skips the member's own posts.
  """
  def filtered_pattern(_post, %{tags: tags, keywords: keywords})
      when map_size(tags) == 0 and keywords == [],
      do: nil

  def filtered_pattern(post, %{tags: tags, keywords: keywords}) do
    matched_tag(post, tags) || matched_keyword(post, keywords)
  end

  @doc """
  Compile one keyword/phrase pattern into a case-insensitive regex.

  `*` becomes "any run of characters"; the literal segments between are escaped,
  so no user input reaches the regex engine as syntax. With `whole_word` the
  match is bounded by word boundaries, except on a side the pattern opens with a
  `*` (that side is deliberately affix/substring). Returns `nil` if the pattern
  cannot compile (defensive; the changeset already caps the length).
  """
  def compile_pattern(pattern, whole_word) do
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

  defp matched_tag(_post, tags) when map_size(tags) == 0, do: nil

  defp matched_tag(post, tags) do
    Enum.find_value(post_tags(post), fn tag ->
      tags[String.downcase(tag.name)] || tags[tag.slug]
    end)
  end

  defp matched_keyword(_post, []), do: nil

  defp matched_keyword(post, keywords) do
    text = post_text(post)
    Enum.find_value(keywords, fn {pattern, re} -> Regex.match?(re, text) && pattern end)
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
