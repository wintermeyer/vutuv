defmodule Vutuv.ContentFilters.ContentFilter do
  @moduledoc """
  One entry in a member's private content filter (issue #940): a **tag** to
  mute, or a **keyword/phrase** (with `*` wildcards) to hide from their feed.

  It is the member's own, viewer-only deny list — silent and one-directional
  (it never touches the author or anyone else, never notifies, never appears in
  the public agent formats). Because it reveals what a member dislikes it is
  owner-only and rides along in the GDPR export.

  `kind`:
    * `:tag` — matches a post carrying that tag (by slug or name).
    * `:keyword` — matches the keyword/phrase in the post's body **and** its
      tags/hashtags. `whole_word` (default true) keeps `cess` from hiding
      "su**cess**"; a `*` in the pattern opts into affix/substring matching and
      overrides the boundary on that side.

  `expires_at` is an optional snooze (`nil` = permanent); the column exists now,
  the UI for it comes later.
  """

  use VutuvWeb, :model

  @kinds [:tag, :keyword]

  # A muted tag slug is short; a muted phrase can be a few words. Capped so a
  # pathological pattern can never build a catastrophic regex (issue #940).
  @max_pattern 100

  schema "content_filters" do
    belongs_to(:user, Vutuv.Accounts.User)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:pattern, :string)
    field(:whole_word, :boolean, default: true)
    field(:expires_at, :utc_datetime)

    timestamps()
  end

  @doc "The valid filter kinds (`:tag`, `:keyword`)."
  def kinds, do: @kinds

  @doc "The maximum pattern length."
  def max_pattern, do: @max_pattern

  @doc """
  Changeset for a new filter. `user_id` is set by the caller (never cast), so a
  request can only ever add a filter to its own list.
  """
  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:kind, :pattern, :whole_word, :expires_at])
    |> update_change(:pattern, &normalize_pattern/1)
    |> validate_required([:kind, :pattern])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:pattern, min: 1, max: @max_pattern)
    # A pattern that is only wildcards/whitespace would hide the whole feed.
    |> validate_format(:pattern, ~r/[^\s*]/,
      message: "must contain something to match, not only wildcards"
    )
    |> unique_constraint([:user_id, :kind, :pattern], message: "you already mute this")
  end

  # Trim and collapse inner whitespace so "  machine   learning " and
  # "machine learning" are the same phrase (and the same unique key).
  defp normalize_pattern(nil), do: nil

  defp normalize_pattern(value) do
    value |> String.trim() |> String.replace(~r/\s+/u, " ")
  end
end
