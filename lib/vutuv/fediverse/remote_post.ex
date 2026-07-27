defmodule Vutuv.Fediverse.RemotePost do
  @moduledoc """
  One post by an account somebody here follows, cached so it can appear in that
  member's home feed (issue #1161).

  The sibling of `Vutuv.Fediverse.Note` (a reply written under a member's post)
  and deliberately shaped like it: plain text only, an audience that decides who
  may read it, and a hard clock. The differences are what the two things are:

    * a Note hangs off the **post it answers**; a RemotePost hangs off the
      **account that wrote it**, because several members can follow the same
      account and there is only ever one copy of the post.
    * a Note carries `checked_at` and is re-asked about at its origin. A
      RemotePost is not: a followed account's stream is pushed here
      continuously, so an edit or a withdrawal arrives on its own, and re-asking
      about every cached post of every account our members read would be far
      heavier than the per-reply check it would resemble. The ceiling and the
      upstream `Delete` are the whole retention story.
    * a Note's audience may be `direct` or `unknown`, because it had to be
      stored in order to reach the member it was addressed to. A post nobody
      here was addressed in is simply not stored, so only the three public-ish
      audiences exist.

  There is no avatar column and no picture of any kind. Pictures are issue
  #1163, and until then the card renders initials and links to the origin.
  """

  use VutuvWeb, :model

  # `public` — addressed to the public collection: on the timelines of that
  # server, and here it renders to whoever follows the account.
  # `unlisted` — public but kept out of that server's discovery surfaces. It is
  # still deliverable to followers, which is exactly what the feed shows.
  # `followers` — followers only. Renders solely to a member whose own follow is
  # accepted, and never leaves through a public surface.
  @audiences ~w(public unlisted followers)

  # The subset that renders to whoever follows the account, rather than to
  # accepted followers only.
  @open_audiences ~w(public unlisted)

  @kinds ~w(note question)

  # Remote URIs are unbounded in theory. Capped in **bytes**, because
  # `object_uri` is part of a btree unique index whose key has a hard size limit
  # — a hostile multi-kilobyte id must fail the changeset, never the index
  # insert (which would be a 500 out of the inbox).
  @max_uri_bytes 2_048

  # Long enough for any real post out there (Mastodon's own ceiling is 500
  # characters and some servers raise it, a poll adds its options), short enough
  # that a hostile server cannot park a novel per delivery.
  @max_content 10_000

  # A content warning is a headline, not a second post.
  @max_summary 500

  schema "fediverse_posts" do
    field(:object_uri, :string)
    field(:in_reply_to_uri, :string)
    field(:origin_url, :string)
    field(:content_text, :string)
    field(:summary, :string)
    field(:sensitive, :boolean, default: false)
    field(:audience, :string)
    field(:kind, :string, default: "note")
    field(:published_at, :utc_datetime)
    field(:received_at, :utc_datetime)
    field(:expires_at, :utc_datetime)

    belongs_to(:remote_account, Vutuv.Fediverse.RemoteAccount)
  end

  @doc "The audiences a stored post can have."
  def audiences, do: @audiences

  @doc "The object types a stored post can have."
  def kinds, do: @kinds

  @doc "The longest remote text a post may carry."
  def max_content, do: @max_content

  @doc "The longest content warning a post may carry."
  def max_summary, do: @max_summary

  @doc """
  The audiences readable by anyone who follows the account, rather than by
  accepted followers only.

  The **list** rather than a second predicate, because the feed query has to
  test it in SQL (`p.audience in ^open_audiences()`) while the card tests it in
  Elixir (`open?/1`). One vocabulary, so a new audience value cannot open in the
  query and close in the card.
  """
  def open_audiences, do: @open_audiences

  @doc """
  Whether the post is readable by anyone who follows the account, rather than
  by accepted followers only.

  Anything followers-only counts as restricted: never widen the author's
  audience.
  """
  def open?(%__MODULE__{audience: audience}), do: audience in @open_audiences

  @doc """
  Whether the author put the post behind a content warning, or marked it
  sensitive. Either one closes the lid: the card shows the warning (or a plain
  "sensitive" line) and reveals the text on a click, which is the one thing the
  author asked for.
  """
  def warned?(%__MODULE__{} = post),
    do: post.sensitive or (is_binary(post.summary) and post.summary != "")

  @doc "Where a human reads the original: the post's own page, or its id."
  def origin(%__MODULE__{origin_url: url}) when is_binary(url) and url != "", do: url
  def origin(%__MODULE__{object_uri: uri}), do: uri

  @doc "Whether this is a poll rather than an ordinary post."
  def question?(%__MODULE__{kind: "question"}), do: true
  def question?(%__MODULE__{}), do: false

  def changeset(%__MODULE__{} = post, attrs) do
    post
    |> cast(attrs, [
      :object_uri,
      :in_reply_to_uri,
      :origin_url,
      :summary,
      :sensitive,
      :audience,
      :kind,
      :published_at,
      :received_at,
      :expires_at
    ])
    # Cast on its own, with no empty values: since issue #1163 a post can be a
    # photograph and nothing else, and its body is then genuinely the empty
    # string. Ecto's default `:empty_values` reads "" as "not given", which
    # would drop the change and leave the NOT NULL column with a nil.
    |> cast(attrs, [:content_text], empty_values: [])
    # And so it cannot be `validate_required` either (which reads "" as missing
    # too). The column stays NOT NULL, and both write paths in `Vutuv.Fediverse`
    # compute the body through one `is_binary` gate, so it is never nil.
    |> validate_required([
      :object_uri,
      :audience,
      :kind,
      :published_at,
      :received_at,
      :expires_at
    ])
    |> validate_inclusion(:audience, @audiences)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:object_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:in_reply_to_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:origin_url, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:content_text, max: @max_content)
    |> validate_length(:summary, max: @max_summary)
    |> unique_constraint(:object_uri)
  end
end
