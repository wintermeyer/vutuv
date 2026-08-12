defmodule Vutuv.SlugHelpers do
  @moduledoc false

  import Ecto.Query
  alias Vutuv.Handles
  alias Vutuv.Mentions
  alias Vutuv.Repo

  @short_sha_length 8

  # User handles follow the Twitter username mechanism. The length ceiling is
  # the single source `Vutuv.Handles.max_length/0`, so generation can never
  # produce a handle the validation would reject. A suffixed handle stays short
  # regardless: 6 (base) + 1 ("_") + 8 (short sha) characters.
  @handle_max_length Handles.max_length()
  @handle_base_with_suffix 6

  @doc """
  Generates a unique user handle (the @username) from the resource's string
  representation, Twitter-style: lowercase letters, digits and underscores,
  at most #{@handle_max_length} characters. A collision with an existing
  value or a `reserved` word gets a short-sha suffix instead of failing.
  """
  def gen_handle_unique(resource, model, slug_field, reserved \\ []) do
    handle = resource |> to_string() |> handleize()

    # A handle already linked from a post is treated like a collision: an
    # auto-generated name never lands on one (it gets the short-sha suffix
    # instead), so a fresh account can't inherit those @handle links.
    taken =
      handle == "" or handle in reserved or
        Repo.exists?(from(s in model, where: field(s, ^slug_field) == ^handle)) or
        Mentions.mentioned_in_posts?(handle)

    if taken do
      base = handle |> String.slice(0, @handle_base_with_suffix) |> String.trim("_")
      String.trim_leading("#{base}_#{short_sha()}", "_")
    else
      handle
    end
  end

  @doc """
  Normalizes free text into a handle body (no uniqueness check): downcased,
  transliterated, non-`[a-z0-9_]` runs collapsed to `_`, capped at
  #{@handle_max_length} chars. The pure core of `gen_handle_unique/4`, exposed
  so callers that manage their own uniqueness (the legacy-username backfill)
  can reuse the exact same normalization.
  """
  def handleize(text) do
    text
    |> handle_body()
    |> String.slice(0, @handle_max_length)
    |> String.trim("_")
  end

  # The grammar itself, without the handle's length ceiling: a tag slug shares
  # it (`tagify/1`) and may run to 60 characters.
  defp handle_body(text) do
    text
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9\s_-]/u, "")
    |> String.replace(~r/[\s-]+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  @german_folds %{"ä" => "ae", "ö" => "oe", "ü" => "ue", "ß" => "ss"}

  # ASCII-fold the already-downcased text instead of letting the character
  # filter swallow it ("Prüfer" must become "pruefer", not "prfer"): German
  # specials get their two-letter forms, everything else loses its
  # diacritics via Unicode decomposition (é -> e).
  defp transliterate(text) do
    text
    |> String.replace(Map.keys(@german_folds), &Map.fetch!(@german_folds, &1))
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  # The symbols that are part of a technology's name rather than punctuation in
  # it (issue #1337). Deleting them made `c++`, `c#`, `c` and `µc` slugify to
  # the same `c`, so three of the four lived behind a random collision suffix
  # and the readable `/tags/c` belonged to C++. Deliberately a short, explicit
  # list and not a general rule: each entry is a name people actually write.
  #
  # Each is anchored so a stray symbol does not turn into a word — a `#` only
  # counts when it follows the name it belongs to, a `+` when it follows the
  # name or another `+`, and a `.` only at the very front (`.net`, while
  # `node.js` keeps the separator it has always had).
  @tag_symbol_words [
    {~r/^\./, "dot"},
    {~r/(?<=[a-z0-9])#/u, "sharp"},
    {~r/(?<=[a-z0-9+])\+/u, "p"},
    {~r{/}, "_"}
  ]

  @doc """
  A **tag** slug: the handle grammar, `^[a-z0-9_]+$`, with the technology
  symbols spelled out first.

      iex> Vutuv.SlugHelpers.tagify("C++")
      "cpp"

      iex> Vutuv.SlugHelpers.tagify("Machine Learning")
      "machine_learning"

  Tags have their own slugifier rather than sharing `slugify_downcase/1` with
  organizations, job postings and CV sections, because only a tag slug is also
  the name of that tag's fediverse actor (#1330). That name has to survive
  every server out there, which means the narrowest local part any of them
  accepts — the same grammar `Vutuv.Handles` already enforces for a member
  handle. A hyphen is the better character for the other three: it is the web's
  word separator and reads to a crawler as one, and nothing federates them.

  Answers `""` when nothing keyable is left, which is the caller's cue to fall
  back to a generated slug (`gen_tag_slug_unique/3`).
  """
  def tagify(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> apply_symbol_words()
    |> handle_body()
  end

  defp apply_symbol_words(text) do
    Enum.reduce(@tag_symbol_words, text, fn {pattern, word}, acc ->
      String.replace(acc, pattern, word)
    end)
  end

  @doc """
  Like `gen_slug_unique/4` but for tags: `tagify/1` for the body, and a
  collision suffix joined with `_` rather than `.` so the result stays inside
  the actor grammar.
  """
  def gen_tag_slug_unique(value, model, slug_field) do
    slug = tagify(value)

    taken =
      Repo.one(
        from(s in model,
          where: field(s, ^slug_field) == ^slug,
          limit: 1,
          select: field(s, ^slug_field)
        )
      )

    case {taken, slug} do
      {_, ""} -> short_sha()
      {nil, slug} -> slug
      {_, slug} -> "#{slug}_#{short_sha()}"
    end
  end

  defp gen_slug(resource) do
    resource
    |> to_string()
    |> slugify_downcase()
  end

  @doc """
  The slug of everything that is **not** a tag — organizations, job postings,
  CV sections: downcased, transliterated, separator runs to `-`.
  """
  def slugify_downcase(text) do
    text
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.trim("-")
  end

  def gen_slug_unique(resource, slug_field),
    do: gen_slug_unique(resource, resource.__struct__, slug_field)

  # `reserved` words (e.g. route prefixes, for user slugs) are treated like a
  # database collision: the generated slug gets the short-sha suffix.
  def gen_slug_unique(resource, model, slug_field, reserved \\ []) do
    slug = gen_slug(resource)

    taken =
      if slug in reserved do
        slug
      else
        Repo.one(
          from(s in model,
            where: field(s, ^slug_field) == ^slug,
            limit: 1,
            select: field(s, ^slug_field)
          )
        )
      end

    ensure_slug(taken, slug, resource)
  end

  # When the name slugifies to nothing (pure symbols / non-latin), fall back to a
  # guaranteed-valid `[a-z0-9]` slug rather than the raw resource string, which
  # would put spaces/uppercase/symbols into a public URL and the sitemap.
  defp ensure_slug(nil, "", _resource), do: short_sha()

  defp ensure_slug(nil, slug, _), do: slug

  defp ensure_slug(_, "", _resource), do: short_sha()

  defp ensure_slug(_, slug, _), do: "#{slug}.#{short_sha()}"

  defp short_sha do
    @short_sha_length
    |> div(2)
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
