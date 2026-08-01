defmodule Vutuv.Fediverse.Note do
  @moduledoc """
  One reply written on another network under a member's post (issues #1069 and
  #1071).

  This is the first content vutuv stores that its own members did not write, so
  every field here is either something the member needs in order to read the
  answer, or something the deletion path needs in order to work:

    * `object_uri` — the note's own AP id. Unique: a redelivery upserts, and an
      upstream `Update`/`Delete` finds its row on this key.
    * `actor_uri`, `handle`, `display_name` — who said it, in the form the card
      shows (`@handle@host`) and links out to. Cosmetic and hostile, so capped.
    * `content_text` — **plain text, never HTML.** Reduced by
      `Vutuv.RemoteHtml.to_text/2` at the inbox, so nothing a stranger wrote is
      ever rendered `raw`, the agent-format siblings get the value for free and
      the cap is well defined in characters.
    * `audience` — how it was addressed. Only `"public"` is public; the other
      three render to the addressed member alone (issue #1071).
    * `inbox_uri` — where an answer to this reply is delivered (issue #1070).
      Free to keep: the inbox verifies every delivery against the sender's
      freshly fetched actor document, which carries it, so storing it here means
      answering costs no network call on the member's request path. Nullable,
      since notes stored before issue #1070 have none.
    * `received_at` / `checked_at` / `expires_at` — the retention triple.

  There is no avatar column and there never will be: the card renders initials
  and links to the origin, so vutuv does not host a third party's picture.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.Handle

  @audiences ~w(public followers direct unknown)

  # Remote URIs are unbounded in theory. Cap them in **bytes**, because
  # `object_uri` is part of a btree unique index whose key has a hard size
  # limit — a hostile multi-kilobyte id must fail the changeset, never the index
  # insert (which would be a 500 out of the inbox).
  @max_uri_bytes 2_048

  # Long enough for any real post on those networks (Mastodon's own ceiling is
  # 500 characters, some servers raise it), short enough that a hostile server
  # cannot park a novel per delivery.
  @max_content 10_000

  # A content warning is a headline, not a second post.
  @max_summary 500

  @doc "The audience values a delivered note is classified into."
  def audiences, do: @audiences

  @doc "The longest remote text a note may carry."
  def max_content, do: @max_content

  @doc "The longest content warning a note may carry."
  def max_summary, do: @max_summary

  @doc """
  Whether the note's author put it behind a content warning. The card then
  renders the warning as the closed lid and reveals the text on a click, which
  is the one thing that author asked for.
  """
  def warned?(%__MODULE__{summary: summary}), do: is_binary(summary) and summary != ""

  schema "fediverse_notes" do
    field(:object_uri, :string)
    field(:actor_uri, :string)
    field(:origin_url, :string)
    field(:in_reply_to_uri, :string)
    field(:inbox_uri, :string)
    field(:handle, :string)
    field(:display_name, :string)
    field(:content_text, :string)
    field(:summary, :string)
    field(:audience, :string)
    field(:received_at, :utc_datetime)
    field(:checked_at, :utc_datetime)
    field(:expires_at, :utc_datetime)

    # The origin's own figures for this reply (issue #1283), exactly as on
    # `Vutuv.Fediverse.RemotePost` — see the block there for why they are
    # nullable and why nothing casts them.
    field(:likes_count, :integer)
    field(:shares_count, :integer)
    field(:counts_checked_at, :utc_datetime)
    field(:counts_etag, :string)
    field(:counts_failures, :integer, default: 0)

    # The stored account behind `actor_uri`, when we have one (issue #1162).
    # Virtual because a note is keyed to its author by URI, not by a foreign
    # key; every loader fills it through the one join that knows why (see the
    # private `notes_with_account/0` in `Vutuv.Fediverse`). Nil means "we do not
    # know them", and then the card's handle links straight out instead of
    # inward.
    field(:account_id, :binary_id, virtual: true)

    belongs_to(:post, Vutuv.Posts.Post)
  end

  @doc """
  Whether everyone may see this note, or only the member it was addressed to.

  The single gate the thread renderer, the count line, the agent-format doc
  builder and the freshness check all read, so they cannot drift apart. Anything
  we could not classify counts as private: never widen the sender's audience.
  """
  def public?(%__MODULE__{audience: "public"}), do: true
  def public?(%__MODULE__{}), do: false

  @doc """
  Whether a like on this reply could actually reach its author (issue #1270):
  we hold the inbox to deliver it to.

  Replies stored before issue #1070 carry none — the column arrived with the
  answering feature — and for those the card offers no heart rather than one
  that refuses, because a marker written for a `Like` that never leaves paints a
  heart the author's server knows nothing about. They age out with the
  six-month retention.
  """
  def likeable?(%__MODULE__{inbox_uri: inbox}), do: is_binary(inbox) and inbox != ""

  @doc """
  How the card names the author: `@handle@host`, the form every one of these
  networks uses. Shared with the follower list and the reaction chips
  (`Vutuv.Fediverse.Handle`), so one person reads the same way everywhere.
  """
  def display_handle(%__MODULE__{handle: handle, actor_uri: actor_uri}),
    do: Handle.display(handle, actor_uri)

  @doc "The server this note came from, for the card's footer and the ledger."
  defdelegate host(uri), to: Handle

  @doc "Where a human reads the original: the note's own page, or its id."
  def origin(%__MODULE__{origin_url: url}) when is_binary(url) and url != "", do: url
  def origin(%__MODULE__{object_uri: uri}), do: uri

  def changeset(%__MODULE__{} = note, attrs) do
    note
    |> cast(attrs, [
      :object_uri,
      :actor_uri,
      :origin_url,
      :in_reply_to_uri,
      :inbox_uri,
      :handle,
      :display_name,
      :content_text,
      :summary,
      :audience,
      :received_at,
      :checked_at,
      :expires_at
    ])
    |> validate_required([
      :object_uri,
      :actor_uri,
      :content_text,
      :audience,
      :received_at,
      :expires_at
    ])
    |> validate_inclusion(:audience, @audiences)
    |> validate_length(:object_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:actor_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:origin_url, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:in_reply_to_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:inbox_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:handle, max: 255)
    |> validate_length(:display_name, max: 255)
    |> validate_length(:content_text, max: @max_content)
    |> validate_length(:summary, max: @max_summary)
    |> unique_constraint(:object_uri)
  end
end
