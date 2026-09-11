defmodule Vutuv.Tags.ExternalPost do
  @moduledoc """
  One post another server's public tag timeline carried (issue #2126): plain
  text, a link to the original, and who wrote it.

  **Text and a link, never a picture.** Every foreign image would have to go
  through the AI image gate, and on a busy tag most posts carry one; the
  language arrives declared, so even knowing what language this is costs no
  model call. `text` is already reduced to plain text by
  `Vutuv.Tags.ExternalTagClient` (through `Vutuv.RemoteHtml`, the one place
  remote HTML becomes something we keep) — never render it with `raw/1`.

  Deliberately **not** a row in `fediverse_posts` — see the migration for what a
  cached ActivityPub object drags behind it.

  Nothing here is user-writable — it is server-writable, which carries the same
  hazard and one more besides. A value too long for its column raises Postgres
  22001 on a path with no form in front of it, and **`validate_length/3` cannot
  be the guard against that**: it counts graphemes while `varchar(n)` counts
  codepoints, so 100 ZWJ family emoji pass a `max: 255` check as 100 characters
  and reach the column as 700. Hence the two rules here. A value that is
  somebody's **chosen spelling of themselves** — their display name, their
  address — goes in a `text` column and is clamped for display rather than
  refused, because dropping a stranger's post over the length of their name is
  the wrong answer. A value that is a **token** keeps its bounded column and is
  capped in **bytes**, which in UTF-8 are never fewer than the codepoints the
  column counts, so the check is conservative and can never be overrun.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [scrub_nul: 1]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Handle

  # The clamp the client applies (`Vutuv.SocialFeed.Post.truncate/1`) is 500
  # characters; this is the backstop under it, on a `text` column.
  @max_text 1_000

  # What a display identity may take up here. Not a column limit — those two are
  # `text` — but the ceiling on what a stranger's server may park in a row this
  # installation shows: `Vutuv.Tags.ExternalTagClient` clamps to it, and a value
  # that somehow arrives longer is refused rather than stored whole.
  @max_display 255

  # Bounded columns, capped in bytes. `remote_id` also rides a btree unique
  # index, so it cannot be widened to text without weighing that entry against
  # Postgres' ~2704-byte limit.
  @max_id 255
  @max_language 32

  # Both addresses live in `text` columns, so this is not the column's limit —
  # it is the ceiling on what a stranger's server may park here at all, the
  # same 2048 bytes the fediverse URI sources cap at.
  @max_url 2_048

  schema "external_tag_posts" do
    field(:source, :string)
    field(:remote_id, :string)
    field(:url, :string)
    field(:text, :string)
    field(:author_name, :string)
    field(:author_acct, :string)

    # The server the **author** lives on — very rarely the one we asked. A
    # public tag timeline is a mixed bag: a post about Koblenz found through
    # troet.cafe was usually written somewhere else entirely. `source` says
    # where we looked; this says whose words these are, and it is what every
    # card, the operator's blocklist and the reader's own muted-server list
    # read. NULL only for a row the release before #2127 wrote, which is why
    # every reader drops such a row rather than falling back to `source` — that
    # fallback is the card claiming the author lives on a server they may never
    # have used.
    field(:author_host, :string)
    field(:author_url, :string)
    field(:language, :string)
    field(:published_at, :utc_datetime)

    # Set by a member's report, which blanks the words and keeps the row as the
    # key that stops the next pull writing it back — `Vutuv.Tags.ExternalPosts.report/2`
    # owns that reasoning (issue #2127).
    field(:reported_at, :utc_datetime)

    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  @fields ~w(tag_id source remote_id url text author_name author_acct author_host
             author_url language published_at)a

  # `author_host` is required on the way in even though the column is nullable:
  # the column has to take a NULL because the release before #2127 wrote rows
  # without it, and a reader that cannot say whose server a post is on refuses
  # to draw it. Nothing this release writes should ever be in that state.
  @required ~w(tag_id source remote_id url text author_host published_at)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @fields)
    # A NUL byte in a remote string is not a length problem and no length check
    # would catch it: Postgres refuses one in a text value outright, so it is
    # the other way a display name can raise inside the insert.
    |> scrub_nul()
    |> validate_required(@required)
    |> validate_length(:source, max: BlockedInstance.max_host(), count: :bytes)
    |> validate_length(:author_host, max: BlockedInstance.max_host(), count: :bytes)
    |> validate_length(:remote_id, max: @max_id, count: :bytes)
    |> validate_length(:language, max: @max_language, count: :bytes)
    |> validate_length(:url, max: @max_url, count: :bytes)
    |> validate_length(:author_url, max: @max_url, count: :bytes)
    |> validate_length(:text, max: @max_text)
    |> validate_length(:author_name, max: @max_display, count: :bytes)
    |> validate_length(:author_acct, max: @max_display, count: :bytes)
    |> unique_constraint(:remote_id, name: :external_tag_posts_tag_id_source_remote_id_index)
    |> foreign_key_constraint(:tag_id)
  end

  @doc """
  The author's full address, `@name@host` — the thing a reader has to be able to
  copy and find them by.

  Built through `Vutuv.Fediverse.Handle.display/3`, the one formatter for this,
  because the Mastodon REST `acct` is two different values: bare (`ada`) for
  somebody local to the server we asked, and `ada@elsewhere` for anybody else.
  Both come back here as the whole address, so a reader never sees a half one.
  """
  def address(%__MODULE__{} = post) do
    Handle.display(local_name(post.author_acct), post.author_url, post.author_host)
  end

  @doc """
  The name to head the card with: what the author calls themselves, their
  address if they call themselves nothing, and the link as the last resort.

  The same fallback ladder `Vutuv.Fediverse.RemoteAccount.label/1` walks, so a
  post found through a tag and a post from a followed account are headed the
  same way. Two rungs rather than three: `author_host` is required, so
  `address/1` always answers at least `@host`.
  """
  def label(%__MODULE__{} = post), do: post.author_name || address(post)

  @doc """
  The name half of the address, without the server — the monogram's source.

  `Vutuv.Fediverse.RemoteAccount`'s twin takes the bare `handle` column for this
  and its doc says why: the whole address starts with an `@`, so
  `VutuvWeb.UI.name_initials/1` would answer `"@"` for it. The Mastodon `acct`
  is bare for an author local to the server we asked and `name@host` for
  everybody else, so the split has to happen somewhere; it happens here.
  """
  def author_username(%__MODULE__{author_acct: acct}), do: local_name(acct)

  @doc """
  Where this post really lives — its own address on its own server.

  This installation serves no page for it (we hold text and a link, nothing
  else), so this is the only address there is. The remote twin of
  `Vutuv.Posts.path/1`, and what `Vutuv.Fediverse.subject_origin/1` answers for
  this kind.

  What a card links to, and never the test for "is this the same post" —
  `origin_key/1` is that.
  """
  def origin(%__MODULE__{url: url}), do: url

  @doc """
  What makes two stored rows copies of **one** original: the normalised address
  of the post, **and the server its author lives on** (issue #2164).

  The rows are keyed on tag, server and remote id, so the same status read off
  five servers under two tags is ten rows with nothing in that key to relate
  them. The address does relate them — but it is `status["url"]` copied verbatim
  from whichever server we polled, validated only as a web URL, and a member may
  name any host as a tag source. So the address **alone** is a string a stranger
  controls: one server claiming another's permalink would, on its own say-so,
  have taken down honest copies of somebody else's post everywhere here and kept
  them out. `author_host` is the second half for that reason, and it is free:
  over 78 stored rows on a copy of production, the two keys group identically
  (43 groups either way), because no original was ever carried under two
  different author hosts. It does not make the pair unforgeable — a lying server
  can claim both fields — but it closes the case where only the address agrees.

  **`author_acct` cannot serve.** Mastodon writes it bare (`pruef_de`) on the
  author's own server and qualified (`pruef_de@mastodon.social`) everywhere
  else, so four of the measured originals carry two spellings of one author;
  `author_host` is the uniform one.

  The address is **normalised**, and each rule is a shape the same post really
  arrived under. A redirect wrapper is not a second original: Bridgy Fed serves
  one Bluesky post as `bsky.brid.gy/r/<address>` and `fed.brid.gy/r/<address>`,
  and both stood here, same author and same second, with nothing relating them.
  A trailing slash or a fragment is the same address said differently, which the
  ingest gate has to see through or a reported post walks back in under a variant
  spelling. And the host follows the rule the rest of this codebase already
  applies to a foreign host — `Vutuv.Fediverse.BlockedInstance.normalize_host/1`
  for the case and the trailing dot, `Vutuv.Fediverse.strip_www/1` for the fold
  that module publishes so nobody keeps their own copy of it.

  **The query stays**, which is why neither `Vutuv.WebVerification.normalize_url/1`
  nor `Vutuv.Profiles.VerifiedLinks.normalize/1` can serve here: both drop it,
  and on software that names a post in its query string two different posts would
  key alike — this key decides whose words get blanked, so it errs towards
  telling two posts apart.
  """
  def origin_key(%{url: url, author_host: host}), do: {normalize_origin(url), host}

  defp normalize_origin(url) when is_binary(url),
    do: url |> URI.parse() |> unwrap_redirect() |> canonical_address()

  # `…/r/https://bsky.app/…`, and the same address percent-encoded — the wrapped
  # address is the post's own either way. Read out of the **path** only: a query
  # parameter is where a server puts somebody else's address for its own reasons,
  # and unwrapping that would relate two unrelated posts. A post whose own path
  # happens to end in an address is read as a wrapper around it, which the
  # author's half of the key bounds to that one author's rows. Recurses, since
  # each step is strictly shorter than the last.
  defp unwrap_redirect(%URI{path: path} = uri) when is_binary(path) do
    case Regex.run(~r{/(https?://.+)\z}, decoded(path)) do
      [_whole, embedded] -> embedded |> URI.parse() |> unwrap_redirect()
      nil -> uri
    end
  end

  defp unwrap_redirect(uri), do: uri

  defp decoded(path) do
    URI.decode(path)
  rescue
    ArgumentError -> path
  end

  # `URI.to_string/1` puts it back together, so the default port, the userinfo
  # and the query keep whatever rules it applies rather than a second set here.
  # The path keeps its case, where two spellings really are two things.
  defp canonical_address(%URI{} = uri) do
    URI.to_string(%URI{
      uri
      | host: canonical_host(uri.host),
        fragment: nil,
        path: uri.path |> to_string() |> String.trim_trailing("/")
    })
  end

  defp canonical_host(host) when is_binary(host) do
    case BlockedInstance.normalize_host(host) do
      nil -> host
      normalized -> Fediverse.strip_www(normalized)
    end
  end

  defp canonical_host(host), do: host

  defp local_name(acct) when is_binary(acct), do: acct |> String.split("@") |> hd()
  defp local_name(_acct), do: nil

  @doc "How much of a display identity is kept — the client clamps to it."
  def max_display, do: @max_display

  @doc "The longest token this table will store as a remote id."
  def max_id, do: @max_id

  @doc "The longest declared language code this table will store."
  def max_language, do: @max_language
end
