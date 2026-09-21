defmodule Vutuv.ScreenshotTrust.Host do
  @moduledoc """
  One trusted site: a host whose link screenshots skip the AI image scan, plus
  an optional note saying why.

  Admin-written (the editor is `/admin/screenshots?tab=trusted`), so the
  changeset is where a mistake is caught. A pasted address is reduced to its
  bare host (`HTTPS://www.Tagesschau.de/` is stored as `tagesschau.de`), but
  one that still carries a path is refused rather than cut down: widening a
  pasted article URL to the whole site without a word is not a surprise a
  safety exemption may spring.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [trim_fields: 2]

  # Both columns are varchar(255) (see the migration); Ecto does not enforce a
  # column limit, so an oversized value would raise Postgres 22001.
  @max_length 255

  # A host with at least two labels, optionally behind a leading `*.`. No
  # port, path, userinfo or whitespace; and `*.de` is refused, because a
  # wildcard over a whole top-level domain is never what an admin means.
  @format ~r/^(\*\.)?[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)+$/u

  schema "screenshot_trusted_hosts" do
    field(:host, :string)
    field(:note, :string)

    timestamps()
  end

  @doc "The admin form's changeset: a host and a note."
  def changeset(%__MODULE__{} = host, attrs) do
    host
    |> cast(attrs, [:host, :note])
    |> trim_fields([:host, :note])
    |> update_change(:host, &normalize/1)
    |> validate_required([:host])
    |> validate_length(:host, max: @max_length)
    |> validate_length(:note, max: @max_length)
    |> validate_format(:host, @format,
      message: "must be a site without a path, e.g. tagesschau.de"
    )
    |> unique_constraint(:host)
  end

  @doc """
  A host as entries store it and the check compares it: lowercase, no trailing
  dot, no `www.`, which names the same site. One function for both sides, so
  an entry and a captured address can never be folded differently.
  """
  def canonical(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
    |> Vutuv.Fediverse.strip_www()
  end

  # A pasted address loses its scheme and a trailing slash; a leading `*.` is
  # kept, because it is the one thing that widens an entry to the subdomains.
  defp normalize(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.trim_leading("//")
    |> String.trim_trailing("/")
    |> canonical()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize(host), do: host
end
