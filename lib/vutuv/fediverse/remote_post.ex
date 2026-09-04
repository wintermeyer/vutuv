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

  A post can also **quote** another one (issue #1609, FEP-044f): `quote_uri`
  says what, `quote_authorization_uri` is the consent stamp beside it, and the
  card is drawn only once that consent is established — see `quote_card?/1`.

  Pictures arrive two ways: the author's own attachments (issue #1163,
  `Vutuv.Fediverse.Media` / `Vutuv.Fediverse.RemoteImage`), and — for a
  single-URL post with no attachment and no content warning — the same auto
  link screenshot a member's post gets (`Vutuv.Posts.Screenshots`, one shared
  queue keyed here by `remote_post_id`). Both wait behind the AI image gate
  before anything renders.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [drop_non_web_urls: 2, scrub_nul: 1]

  alias Vutuv.Translations

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
    # The language the origin declared via AS2 contentMap (issue #1488), a
    # lowercase primary language subtag; NULL = the object declared none.
    field(:language, :string)
    # When the language detection last looked (issue #1535) — most origins
    # send no `contentMap`, so this is the column that keeps that pile from
    # being retried forever. Set on every outcome; nothing casts it.
    field(:language_checked_at, :utc_datetime)
    field(:sensitive, :boolean, default: false)
    field(:audience, :string)
    field(:kind, :string, default: "note")
    field(:published_at, :utc_datetime)
    field(:received_at, :utc_datetime)
    field(:expires_at, :utc_datetime)

    # When the origin last confirmed this post is still published (issue
    # #1166). Null until somebody reshares it: the check exists for reshared
    # copies alone, since nothing else here outlives its ceiling.
    field(:checked_at, :utc_datetime)

    # What the origin says about its own post: the size of its `likes` and
    # `shares` collections, when we last asked, the ETag we may ask with, and
    # how many asks in a row have failed (issue #1283,
    # `Vutuv.Fediverse.CountsRefresher`).
    #
    # Null is not zero. Both collections are MAY in ActivityPub and some
    # software serves neither, so an absent figure renders as nothing at all
    # rather than as a `0` we would be inventing.
    #
    # Written by the refresher and nudged by a member's own act, never cast
    # from user input — there is no `:counts` changeset for that reason.
    field(:likes_count, :integer)
    field(:shares_count, :integer)
    field(:counts_checked_at, :utc_datetime)
    field(:counts_etag, :string)
    field(:counts_failures, :integer, default: 0)

    # What this post quotes (issue #1609), and whether we may draw it as a card.
    #
    # `quote_uri` is what the author's server said they quoted — the canonical
    # id of the quoted object, read from `quote`, `quoteUri` or
    # `_misskey_quote`, whichever of the three aliases that software writes.
    # `quote_authorization_uri` is the FEP-044f stamp beside it: a document on
    # the **quoted** object's host saying its author consented to this exact
    # quote. Neither is a claim we act on until it has been checked.
    #
    # `quote_verified` is the one flag the card reads. True for a self-quote
    # (the author quoting themselves needs nobody's consent) and for a stamp we
    # fetched and matched; false for everything else, including a quote we
    # simply have not resolved yet — so an unchecked row renders as the link it
    # would otherwise have been, never as a card somebody did not agree to.
    #
    # `quote_checked_at` is the resume clock, and it answers one question only:
    # did the resolution ever finish? Every outcome stamps it, the refusals
    # included — it is the scheduler's clock, not a claim that a card came of
    # it — so a row with a `quote_uri` and no stamp is one whose background task
    # died before it wrote anything, and `Vutuv.Fediverse.QuoteResolver` is what
    # goes back for it. Nothing casts it; an edit that moves the quote clears it
    # (`Vutuv.Fediverse.resolve_quote/1`).
    field(:quote_uri, :string)
    field(:quote_authorization_uri, :string)
    field(:quote_verified, :boolean, default: false)
    field(:quote_checked_at, :utc_datetime)

    belongs_to(:remote_account, Vutuv.Fediverse.RemoteAccount)

    # The quoted thing once it is resolved: a cached copy of another account's
    # post, or a vutuv post when the quote points back at this installation.
    # At most one of the two is set, and neither has to be — a quote of
    # something we cannot reach keeps its URI and nothing else.
    #
    # `quoted_post_id` is also this feature's **holder** against
    # `Vutuv.Fediverse.purge_unfollowed_remote_posts/0`: the copy exists because
    # somebody's post quotes it, which is the same claim a reshare (#1166), a
    # boost (#1167) and a lookup (#1211) make.
    belongs_to(:quoted_post, __MODULE__)
    belongs_to(:quoted_local_post, Vutuv.Posts.Post)

    # The pictures the author attached (issue #1163) and the auto link
    # screenshot for a single-URL, picture-less post — the exact machinery a
    # member's post gets (`Vutuv.Posts.Screenshots`), keyed here by
    # `remote_post_id`.
    has_many(:images, Vutuv.Fediverse.RemoteImage)
    has_one(:screenshot, Vutuv.Posts.PostScreenshot, foreign_key: :remote_post_id)
  end

  @doc """
  The longest URI any of the remote address columns may hold, in bytes.

  Public because the ingestion has to know it *before* the changeset does: a
  field an over-long value belongs to may be optional (`quote_uri`), and there
  the value is dropped rather than allowed to fail the whole insert.
  """
  def max_uri_bytes, do: @max_uri_bytes

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
  Whether the author addressed it to the public collection outright — stricter
  than `open?/1`, which also takes `unlisted` in. The twin of
  `Vutuv.Fediverse.Note.public?/1`, and the column half of what a page open to
  everyone may show (`Vutuv.Fediverse.publicly_readable_remote_post?/1` adds the
  retention half).
  """
  def public?(%__MODULE__{audience: "public"}), do: true
  def public?(%__MODULE__{}), do: false

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

  @doc """
  Whether the post says it quotes something at all (issue #1609) — the flag
  behind both halves of the rendering, the card and the plain link fallback.
  """
  def quoting?(%__MODULE__{quote_uri: uri}), do: is_binary(uri) and uri != ""

  @doc """
  Whether the quote may be drawn as a **card** rather than as a link.

  Two things have to hold: we checked the consent (`quote_verified`, set for a
  self-quote or a matched FEP-044f stamp) **and** we hold the quoted post. Either
  one alone renders the link, which is what a reader had before this existed and
  is never wrong.

  Deliberately only the cached-post half. A quote of one of **our** posts sets
  `quoted_local_post_id` and can never set `quote_verified`, because the stamp
  would have to be one this installation issued and it issues none until issue
  #1608 — so that column names a link target, not a card.

  **The card is only as fresh as the last fetch.** `quote_verified` records that
  the stamp matched *when it was read*, and nothing re-reads it: a quoted author
  who withdraws consent afterwards — deleting the `QuoteAuthorization`, taking
  the post down, narrowing its audience — keeps their card here until the copy
  expires. A recheck sweeper is follow-up work, not part of this. Whoever builds
  it inherits this codebase's clock rule: stamp the `*_checked_at` column on the
  branch that decides an object **cannot** be checked, or that object holds the
  front of every batch forever and the sweep silently does nothing (issue #1316).
  """
  def quote_card?(%__MODULE__{} = post),
    do: post.quote_verified and is_binary(post.quoted_post_id)

  @doc """
  What this post quotes, resolved from what is loaded on the row:

    * `{:remote, %RemotePost{}}` — a cached copy of somebody else's post.
    * `{:local, %Vutuv.Posts.Post{}}` — a vutuv post.
    * `{:uri, uri}` — we hold the address and nothing else, either because the
      quote was never resolved or because the caller did not ask for
      `quote_preload/0`.
    * `nil` — the post quotes nothing.

  The **one** answer to "what does this quote", because three surfaces ask it
  and each would otherwise derive it from the two ids and two associations for
  itself: the card, the plain-link fallback, and the agent-format doc builders.
  Dispatched on the id **columns** rather than on the associations, so a caller
  that forgot the preload gets the honest `{:uri, _}` instead of a clause that
  silently does not match.
  """
  def quoted(%__MODULE__{} = post) do
    cond do
      not quoting?(post) -> nil
      is_binary(post.quoted_local_post_id) -> quoted_record(post.quoted_local_post, :local, post)
      is_binary(post.quoted_post_id) -> quoted_record(post.quoted_post, :remote, post)
      true -> {:uri, post.quote_uri}
    end
  end

  defp quoted_record(%Ecto.Association.NotLoaded{}, _kind, post), do: {:uri, post.quote_uri}
  defp quoted_record(nil, _kind, post), do: {:uri, post.quote_uri}
  defp quoted_record(record, kind, _post), do: {kind, record}

  @doc """
  What a card needs loaded to draw a quote — one spec, because every surface
  that renders `remote_post_card/1` reads it and a surface that forgets it
  would quietly draw the link instead of the card.

  Applied with `Repo.preload/2` after the page's own query rather than folded
  into it: the card sites reach a cached post through four different shapes
  (plain, nested under a reshare, under a boost, under a bookmark), and one
  post-hoc preload works for all of them without any of those queries having to
  spell this list out again.
  """
  def quote_preload,
    do: [quoted_post: :remote_account, quoted_local_post: [:user, :organization]]

  def changeset(%__MODULE__{} = post, attrs) do
    post
    |> cast(attrs, [
      :object_uri,
      :in_reply_to_uri,
      :origin_url,
      :summary,
      :language,
      :sensitive,
      :audience,
      :kind,
      :published_at,
      :received_at,
      :expires_at,
      # Cast on the edit path too, not only the insert: Mastodon publishes a
      # quote unapproved and sends an `Update` the moment the stamp arrives, so
      # `quote_authorization_uri` reaches us as an edit far more often than as
      # part of the original `Create` (issue #1609).
      :quote_uri,
      :quote_authorization_uri
    ])
    # Cast on its own, with no empty values: since issue #1163 a post can be a
    # photograph and nothing else, and its body is then genuinely the empty
    # string. Ecto's default `:empty_values` reads "" as "not given", which
    # would drop the change and leave the NOT NULL column with a nil.
    |> cast(attrs, [:content_text], empty_values: [])
    # After both casts, before the validations: remote strings, and a NUL in one
    # raises on insert (issue #1767).
    |> scrub_nul()
    # The URLs a card turns into an `href`. A remote server may put anything
    # here, and `Phoenix.Component.link/1` RAISES on a scheme it does not know,
    # so one `javascript:` value would take down every render of the feed that
    # shows this post. Dropped rather than refused: losing a link beats losing
    # the post.
    |> drop_non_web_urls([:origin_url, :quote_uri])
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
    |> validate_length(:quote_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:quote_authorization_uri, max: @max_uri_bytes, count: :bytes)
    # Whoever writes `language` owns its clock (issue #1535) — and an `Update`
    # carrying no `contentMap` writes it as nil, which has to mean "look again"
    # rather than "undeclared forever".
    |> Translations.reset_language_check()
    |> unique_constraint(:object_uri)
  end
end
