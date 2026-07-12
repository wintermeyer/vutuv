defmodule Vutuv.SlugHelpers do
  @moduledoc false

  import Ecto.Query
  alias Vutuv.Handles
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

    taken =
      handle == "" or handle in reserved or
        Repo.exists?(from(s in model, where: field(s, ^slug_field) == ^handle))

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
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9\s_-]/u, "")
    |> String.replace(~r/[\s-]+/, "_")
    |> String.trim("_")
    |> String.slice(0, @handle_max_length)
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

  defp gen_slug(resource) do
    resource
    |> to_string()
    |> slugify_downcase()
  end

  defp slugify_downcase(text) do
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
    string =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()
      |> Integer.to_string()

    rand =
      :rand.uniform()
      |> Float.to_string()

    :crypto.hash(:sha256, string <> rand)
    |> Base.encode16()
    |> String.downcase()
    |> String.slice(0, @short_sha_length)
  end
end
