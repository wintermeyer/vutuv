defmodule Vutuv.ScreenshotBlocklist.Entry do
  @moduledoc """
  One line of the screenshot blocklist: a domain or a URL this installation
  never captures, plus an optional note saying why.

  Admin-written data (the editor is `/admin/screenshots?tab=blocklist`), so the
  changeset is where a typo is caught: a pattern is normalised to lowercase
  without its scheme, and one that names no host at all is rejected rather than
  stored as a line that silently matches nothing — or, worse, everything.
  """

  use VutuvWeb, :model

  alias Vutuv.ScreenshotBlocklist

  # Both columns are varchar(255) (see the migration); Ecto does not enforce a
  # column limit, so an oversized value would raise Postgres 22001.
  @max_length 255

  schema "screenshot_blocklist_entries" do
    field(:pattern, :string)
    field(:note, :string)

    timestamps()
  end

  def changeset(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:pattern, :note])
    |> update_change(:pattern, &normalize/1)
    |> validate_required([:pattern])
    |> validate_length(:pattern, max: @max_length)
    |> validate_length(:note, max: @max_length)
    |> validate_pattern()
    |> unique_constraint(:pattern)
  end

  # `HTTPS://Heise.DE/News/` and `heise.de/news` are the same rule, so they are
  # stored the same way: one canonical spelling per line keeps the unique index
  # meaningful and the list readable.
  defp normalize(pattern) when is_binary(pattern) do
    pattern
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.trim_leading("//")
    |> String.trim_trailing("/")
  end

  defp normalize(pattern), do: pattern

  defp validate_pattern(changeset) do
    validate_change(changeset, :pattern, fn :pattern, pattern ->
      if ScreenshotBlocklist.parse(pattern),
        do: [],
        else: [pattern: "must name a domain or a URL, e.g. heise.de"]
    end)
  end
end
