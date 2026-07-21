defmodule Vutuv.Jobs.SearchQuery do
  @moduledoc """
  Turns the human `/jobs` board search box into a safe Postgres `to_tsquery`
  string (issue #952).

  The board's motivation is that a role has no single canonical title
  ("Webentwickler" / "Full-Stack Developer" / "PHP Developer" / …), so the box
  has to let one search cover several at once. The grammar it understands, all
  documented on the board itself:

    * **comma / newline / `|` / the word `or`|`oder`** → OR between titles, so
      `Webentwickler, PHP-Entwickler` matches a posting with *either*. This is
      the headline feature and is locale-neutral (unlike Postgres's own English
      `or` keyword, useless to a German visitor typing `oder`).
    * **space between words** → every word must appear (AND).
    * **trailing `*`** → prefix wildcard: `entwickl*` matches Entwickler,
      Entwicklung, … Especially useful because the board indexes with the
      `simple` dictionary (no stemming), so word variants are otherwise distinct.
    * **"quoted words"** → exact phrase (the words adjacent, in order).
    * **leading `-`** → exclude a word from the whole search.

  Every token is reduced to lexeme-safe characters before it reaches SQL, and
  the expression is assembled from non-empty, well-formed pieces only, so
  `to_tsquery('simple', …)` can never raise on visitor input — the reason we
  build the query here rather than hand the raw string to `to_tsquery`, which
  throws on stray punctuation. Returns `nil` when nothing searchable survives
  (the caller treats that as "no text filter").
  """

  # A private-use codepoint no visitor types, used to fence quoted phrases out
  # of the OR/word splitting so a phrase's inner spaces and commas stay intact.
  @sentinel ""

  # Split OR-groups on comma / newline / pipe, or on a standalone `or`/`oder`
  # word (case-insensitive, whitespace- or edge-bounded so "editor"/"corridor"
  # are untouched).
  @or_split ~r/[,\n\r|]+|(?:(?<=\s)|^)(?:or|oder)(?:(?=\s)|$)/iu

  # Lexeme boundary: anything that is not a letter or digit (Unicode-aware, so
  # umlauts stay inside a lexeme and hyphens/`+`/quotes split it).
  @non_lexeme ~r/[^\p{L}\p{N}]+/u

  @doc """
  Builds a `to_tsquery('simple', …)` argument from the raw search box string,
  or `nil` when the input holds no searchable token.
  """
  @spec to_tsquery(binary() | nil) :: binary() | nil
  def to_tsquery(q) when is_binary(q) do
    {protected, phrases} = protect_phrases(q)

    {positive_groups, negatives} =
      protected
      |> String.split(@or_split, trim: true)
      |> Enum.reduce({[], []}, fn group, {groups, negatives} ->
        {pieces, group_negatives} = classify(group, phrases)

        case pieces do
          [] -> {groups, negatives ++ group_negatives}
          _ -> {groups ++ [join_and(pieces)], negatives ++ group_negatives}
        end
      end)

    combine(positive_groups, Enum.uniq(negatives))
  end

  def to_tsquery(_), do: nil

  # --- phrase fencing -------------------------------------------------------

  defp protect_phrases(q) do
    ~r/"[^"]*"/u
    |> Regex.split(q, include_captures: true)
    |> Enum.reduce({[], %{}, 0}, fn part, {parts, phrases, i} ->
      if String.starts_with?(part, ~s(")) and String.ends_with?(part, ~s(")) do
        key = @sentinel <> Integer.to_string(i) <> @sentinel
        {[key | parts], Map.put(phrases, key, String.slice(part, 1..-2//1)), i + 1}
      else
        {[part | parts], phrases, i}
      end
    end)
    |> then(fn {parts, phrases, _i} -> {parts |> Enum.reverse() |> Enum.join(), phrases} end)
  end

  # --- per-group token classification --------------------------------------

  defp classify(group, phrases) do
    group
    |> String.split()
    |> Enum.reduce({[], []}, fn token, {pieces, negatives} ->
      cond do
        Map.has_key?(phrases, token) ->
          add(pieces, negatives, phrase_piece(phrases[token]), :positive)

        String.starts_with?(token, "-") or String.starts_with?(token, "!") ->
          add(pieces, negatives, word_expr(strip_negation(token)), :negative)

        true ->
          add(pieces, negatives, word_expr(token), :positive)
      end
    end)
  end

  defp add(pieces, negatives, nil, _side), do: {pieces, negatives}
  defp add(pieces, negatives, expr, :positive), do: {pieces ++ [expr], negatives}
  defp add(pieces, negatives, expr, :negative), do: {pieces, negatives ++ [expr]}

  defp strip_negation(token) do
    token |> String.replace_prefix("-", "") |> String.replace_prefix("!", "")
  end

  # --- token → tsquery piece -----------------------------------------------

  defp phrase_piece(text) do
    case lexemes(text) do
      [] -> nil
      words -> "(" <> Enum.join(words, " <-> ") <> ")"
    end
  end

  defp word_expr(token) do
    prefix? = String.ends_with?(token, "*")
    core = String.trim_trailing(token, "*")

    case lexemes(core) do
      [] -> nil
      words -> words |> maybe_prefix(prefix?) |> join_and()
    end
  end

  defp maybe_prefix(words, false), do: words

  defp maybe_prefix(words, true) do
    {init, [last]} = Enum.split(words, -1)
    init ++ [last <> ":*"]
  end

  defp lexemes(text) do
    text |> String.downcase() |> String.split(@non_lexeme, trim: true)
  end

  # --- assembly -------------------------------------------------------------

  defp join_and([one]), do: one
  defp join_and(pieces), do: "(" <> Enum.join(pieces, " & ") <> ")"

  defp combine([], []), do: nil

  defp combine(positive_groups, negatives) do
    positive =
      case positive_groups do
        [] -> nil
        [one] -> one
        many -> "(" <> Enum.join(many, " | ") <> ")"
      end

    negated = Enum.map(negatives, &("!(" <> &1 <> ")"))

    [positive | negated]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" & ")
  end
end
