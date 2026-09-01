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

  `account` says **whose** posts the rule reads: `*` (the default) is every
  account, anything else narrows it to the accounts whose handle or display name
  the pattern matches, with the same `*` wildcard. A member following a news
  house receives the same story in a dozen spellings from a dozen of its
  accounts, so the rule that silences one of its phrases belongs on the source
  rather than on the whole timeline: `*@social.heise.de` reaches
  `@heiseonline@social.heise.de` and `@ct_Magazin@social.heise.de` alike, which
  no list of handles typed by hand would keep up with.

  `expires_at` is an optional snooze (`nil` = permanent); the column exists now,
  the UI for it comes later.
  """

  use VutuvWeb, :model

  @kinds [:tag, :keyword]

  # A muted tag slug is short; a muted phrase can be a few words. Capped so a
  # pathological pattern can never build a catastrophic regex (issue #940). The
  # account scope is a handle (`@name@some.server`) and gets the same ceiling,
  # well inside its varchar(255) column.
  @max_pattern 100

  # Every account: what the column has meant since before it existed.
  @every_account "*"

  schema "content_filters" do
    belongs_to(:user, Vutuv.Accounts.User)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:pattern, :string)
    field(:account, :string, default: @every_account)
    field(:whole_word, :boolean, default: true)
    field(:expires_at, :utc_datetime)

    timestamps()
  end

  @doc "The valid filter kinds (`:tag`, `:keyword`)."
  def kinds, do: @kinds

  @doc "The maximum pattern length."
  def max_pattern, do: @max_pattern

  @doc ~S|The account scope meaning "every account": `"*"`.|
  def every_account, do: @every_account

  @doc """
  Whether this filter — or a bare account value — reads every account rather
  than a named few.

  It normalizes what it is given rather than comparing to `*` outright, because
  it is asked of values that never went through the changeset: a rule being
  typed carries whatever is in the field, and an empty one compiles to a regex
  that matches everything, which would silently turn an unscoped draft into a
  rule that skips every post whose account cannot be named.
  """
  def every_account?(%__MODULE__{account: account}), do: every_account?(account)
  def every_account?(account), do: normalize_account(account) == @every_account

  @doc """
  Changeset for a new filter. `user_id` is set by the caller (never cast), so a
  request can only ever add a filter to its own list.
  """
  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:kind, :pattern, :account, :whole_word, :expires_at])
    |> update_change(:pattern, &normalize_pattern/1)
    # An empty account field is the ordinary case, not an omission: the reader
    # who types a word and nothing else means every account.
    |> update_change(:account, &normalize_account/1)
    |> validate_required([:kind, :pattern])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:pattern, min: 1, max: @max_pattern)
    # A pattern that is only wildcards/whitespace would hide the whole feed.
    |> validate_format(:pattern, ~r/[^\s*]/,
      message: "must contain something to match, not only wildcards"
    )
    # The account half has no such rule — `*` is exactly the wildcard-only value
    # it is supposed to carry — but it does share the column's ceiling.
    |> validate_length(:account, min: 1, max: @max_pattern)
    # Four columns, under the three-column index's old NAME. The account had to
    # join the key — the same word may now be muted once per set of accounts —
    # but Ecto matches a constraint by name, so renaming the index would leave
    # the release still serving traffic through a blue/green migration unable to
    # recognise its own duplicate and raise `Ecto.ConstraintError` instead.
    |> unique_constraint([:user_id, :kind, :pattern, :account],
      name: :content_filters_user_id_kind_pattern_index,
      message: "you already mute this"
    )
  end

  # Trim and collapse inner whitespace so "  machine   learning " and
  # "machine learning" are the same phrase (and the same unique key).
  defp normalize_pattern(nil), do: nil

  defp normalize_pattern(value) do
    value |> String.trim() |> String.replace(~r/\s+/u, " ")
  end

  # A blank scope, and a scope written as nothing but wildcards, both mean the
  # same thing as `*` — so they are stored as `*`. Otherwise the unique index
  # would hold three rows that all say "every account" and the card would show
  # three chips claiming three different scopes.
  defp normalize_account(nil), do: @every_account

  defp normalize_account(value) do
    case normalize_pattern(value) do
      "" -> @every_account
      trimmed -> if String.match?(trimmed, ~r/^\*+$/), do: @every_account, else: trimmed
    end
  end
end
