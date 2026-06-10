defmodule Vutuv.SlugHelpers do
  @moduledoc false

  import Ecto.Query
  alias Vutuv.Repo

  @short_sha_length 8

  # User handles follow the Twitter username mechanism (see
  # Vutuv.Accounts.User.slug_changeset/2): 15 characters max, so a suffixed
  # handle is 6 (base) + 1 ("_") + 8 (short sha) characters.
  @handle_max_length 15
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

  defp handleize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/u, "")
    |> String.replace(~r/[\s-]+/, "_")
    |> String.trim("_")
    |> String.slice(0, @handle_max_length)
    |> String.trim("_")
  end

  defp gen_slug(resource) do
    resource
    |> to_string()
    |> slugify_downcase()
  end

  defp slugify_downcase(text) do
    text
    |> String.downcase()
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

  defp ensure_slug(nil, "", resource), do: to_string(resource)

  defp ensure_slug(nil, slug, _), do: slug

  defp ensure_slug(_, "", resource), do: "#{to_string(resource)}.#{short_sha()}"

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
