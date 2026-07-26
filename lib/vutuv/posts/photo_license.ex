defmodule Vutuv.Posts.PhotoLicense do
  @moduledoc """
  The fixed set of licenses a photo post can carry (issue #1104), and the one
  place their labels, deed URLs and machine identifiers live.

  A **fixed vocabulary, never free text**: a stored string stays comparable and
  machine-readable (the agent-format siblings and the schema.org `ImageObject`
  both publish it), and nobody can accidentally publish a half-remembered
  licence sentence that means something other than they think.

  `"arr"` — all rights reserved — is the default and what every post written
  before this feature carries. It is the *absence* of a grant, so it has no
  deed to link; every other value is a Creative Commons 4.0 licence with a
  stable public deed.

  The member's last pick is remembered on their account
  (`users.default_post_license`) and offered on their next photo post, so a
  professional sets it once.
  """

  use Gettext, backend: VutuvWeb.Gettext

  @default "arr"

  # Ordered as the composer's select shows them: the safe default first, then
  # loosening grants.
  @licenses [
    %{value: "arr", short: nil, url: nil, spdx: nil},
    %{
      value: "cc-by-4.0",
      short: "CC BY 4.0",
      url: "https://creativecommons.org/licenses/by/4.0/",
      spdx: "CC-BY-4.0"
    },
    %{
      value: "cc-by-sa-4.0",
      short: "CC BY-SA 4.0",
      url: "https://creativecommons.org/licenses/by-sa/4.0/",
      spdx: "CC-BY-SA-4.0"
    },
    %{
      value: "cc-by-nc-4.0",
      short: "CC BY-NC 4.0",
      url: "https://creativecommons.org/licenses/by-nc/4.0/",
      spdx: "CC-BY-NC-4.0"
    },
    %{
      value: "cc0-1.0",
      short: "CC0 1.0",
      url: "https://creativecommons.org/publicdomain/zero/1.0/",
      spdx: "CC0-1.0"
    }
  ]

  @values Enum.map(@licenses, & &1.value)

  @doc "The default license: all rights reserved."
  def default, do: @default

  @doc "Every license value, in the order the composer offers them."
  def values, do: @values

  @doc "Whether `value` is one of the known licenses."
  def valid?(value), do: value in @values

  @doc """
  `value` if it is a known license, else the default — the chokepoint every
  write goes through, so a tampered form value can never store an unknown
  license (which would render as a blank line and publish nothing meaningful).
  """
  def cast(value) when is_binary(value), do: if(valid?(value), do: value, else: @default)
  def cast(_value), do: @default

  @doc """
  The full human label, e.g. "© All rights reserved" or
  "CC BY 4.0 (attribution required)". What the composer's select and the
  permalink line show.
  """
  def label("arr"), do: gettext("© All rights reserved")

  def label("cc-by-4.0"),
    do: gettext("CC BY 4.0 — reuse with credit")

  def label("cc-by-sa-4.0"),
    do: gettext("CC BY-SA 4.0 — reuse with credit, share alike")

  def label("cc-by-nc-4.0"),
    do: gettext("CC BY-NC 4.0 — non-commercial reuse with credit")

  def label("cc0-1.0"),
    do: gettext("CC0 1.0 — no rights reserved")

  def label(_unknown), do: label(@default)

  @doc """
  The short badge form ("CC BY 4.0"), or `nil` for all-rights-reserved, which
  has no badge — it is the default state, not a grant worth advertising.
  """
  def short(value), do: find(value).short

  @doc "The license deed URL, or `nil` for all-rights-reserved."
  def url(value), do: find(value).url

  @doc """
  The SPDX identifier, or `nil` for all-rights-reserved. What the agent
  formats and the schema.org markup publish, so a machine reads the exact
  license rather than a translated sentence.
  """
  def spdx(value), do: find(value).spdx

  @doc """
  Whether this license grants reuse at all. Drives the one-line explainer
  next to the download button: a downloader of an all-rights-reserved photo
  is being handed a file, not a permission.
  """
  def grants_reuse?(value), do: value != @default and valid?(value)

  defp find(value) do
    Enum.find(@licenses, &(&1.value == value)) || find(@default)
  end
end
