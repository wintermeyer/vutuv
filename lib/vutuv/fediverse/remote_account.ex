defmodule Vutuv.Fediverse.RemoteAccount do
  @moduledoc """
  An account on another network that somebody here follows (issue #1160).

  One row per remote actor, however many members follow it. Written when a
  member resolves a handle, re-synced from the actor document whenever that
  server broadcasts an `Update` of itself, and removed with everything hanging
  off it when the operator blocks its server.

  It is the mirror image of `Vutuv.Fediverse.Follower` (who out there follows
  a member here) and deliberately keeps the same fields: the actor URI is the
  identity, the inbox pair is where activities go, the two display strings are
  cosmetic and untrusted. What it adds is the account's own `summary` — the
  self-description — because deciding whether to follow somebody needs more
  than a handle, and the public key, because a followed account's posts arrive
  signed and have to be verifiable without re-fetching the actor every time.

  `host` is denormalized out of `actor_uri` rather than parsed in SQL: it is
  read by the browser's Server column, its filter and the instance purge, and
  a stored value keeps all three reading the same thing.

  `followers_uri`, `follower_count` and its two timestamps support the
  reach analysis. The count comes from a public ActivityPub collection or
  Mastodon API in the background. It measures possible distribution through a
  repost, not delivery or readership, and may be absent when a server withholds
  it.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [drop_non_web_urls: 2, scrub_nul: 1]

  alias Vutuv.Fediverse.Handle

  # Remote URIs are unbounded in theory; cap generously (they are `text`
  # columns) so a hostile payload cannot store megabytes. actor_uri carries a
  # btree unique index, so its cap also has to stay under Postgres' ~2704-byte
  # key limit — 2048 bytes does.
  @max_uri 2_048

  # The display strings are cosmetic and come from a remote actor document, so
  # `Vutuv.Fediverse.fetch_remote_actor/2` already truncates them to this
  # length; the validation is only a backstop.
  @max_display 255

  # A self-description is prose, so it gets a text column and a generous cap
  # rather than a varchar — the same call the post descriptions made.
  @max_summary 10_000

  schema "fediverse_remote_accounts" do
    field(:actor_uri, :string)
    field(:host, :string)
    field(:handle, :string)
    field(:name, :string)
    field(:summary, :string)
    field(:inbox_uri, :string)
    field(:shared_inbox_uri, :string)
    field(:public_key_id, :string)
    field(:public_key_pem, :string)
    field(:refreshed_at, :utc_datetime)

    # Public ActivityPub audience metadata. It is only potential distribution,
    # never a readership count: followers may overlap or never receive a post.
    field(:followers_uri, :string)
    field(:follower_count, :integer)
    field(:follower_count_checked_at, :utc_datetime)
    field(:follower_count_attempted_at, :utc_datetime)

    # Where this account went (issue #1168), from a verified inbound `Move`.
    # The mirror of `users.moved_to`; nil for everybody who has not moved.
    field(:moved_to, :string)

    # The account's picture (issue #1163): the fingerprinted file we stored, the
    # AI gate's verdict on it, and the URL it came from so a re-delivered actor
    # document does not re-download an unchanged picture. Initials stay the
    # fallback everywhere — a member without a picture and a remote account we
    # have not (or may not) show one for read the same way.
    field(:avatar, :string)
    field(:avatar_moderation, :string)
    field(:avatar_source, :string)

    has_many(:follows, Vutuv.Fediverse.Follow, foreign_key: :remote_account_id)

    timestamps()
  end

  def changeset(%__MODULE__{} = account, attrs) do
    account
    |> cast(attrs, [
      :actor_uri,
      :host,
      :handle,
      :name,
      :summary,
      :inbox_uri,
      :shared_inbox_uri,
      :public_key_id,
      :public_key_pem,
      :refreshed_at,
      :followers_uri,
      :follower_count,
      :follower_count_checked_at,
      :follower_count_attempted_at,
      :moved_to
    ])
    # Remote strings, and a NUL in one raises on insert (issue #1767).
    |> scrub_nul()
    # The URLs that become an `href`: `Phoenix.Component.link/1` raises on a
    # scheme it does not know, so one hostile value would take down every render
    # that shows this row. Dropped rather than refused — see
    # `Vutuv.ChangesetHelpers.drop_non_web_urls/2`.
    |> drop_non_web_urls([:actor_uri, :moved_to])
    |> validate_required([:actor_uri, :host, :inbox_uri])
    |> validate_length(:actor_uri, max: @max_uri, count: :bytes)
    |> validate_length(:inbox_uri, max: @max_uri, count: :bytes)
    |> validate_length(:shared_inbox_uri, max: @max_uri, count: :bytes)
    |> validate_length(:public_key_id, max: @max_uri, count: :bytes)
    |> validate_length(:public_key_pem, max: @max_uri, count: :bytes)
    |> validate_length(:followers_uri, max: @max_uri, count: :bytes)
    |> validate_number(:follower_count, greater_than_or_equal_to: 0)
    |> validate_length(:moved_to, max: @max_uri, count: :bytes)
    |> validate_length(:host, max: @max_display)
    |> validate_length(:handle, max: @max_display)
    |> validate_length(:name, max: @max_display)
    |> validate_length(:summary, max: @max_summary)
    |> unique_constraint(:actor_uri)
  end

  @doc "The longest self-description a row may carry."
  def max_summary, do: @max_summary

  @doc """
  The `@user@host` address to show a member, built by the shared
  `Vutuv.Fediverse.Handle` so a followed account, a follower, a reply and a
  reaction never write the same person two different ways on one page.
  """
  def display_handle(%__MODULE__{} = account),
    do: Handle.display(account.handle, account.actor_uri, account.host)

  @doc """
  Whether this account's cached picture may be shown: we have one and the AI
  gate cleared it. The one chokepoint every surface reads, so "has a file" can
  never drift from "was allowed"; false means initials, which is what a
  picture-less account gets anyway.
  """
  def avatar_ready?(%__MODULE__{avatar: file, avatar_moderation: state}),
    do: is_binary(file) and file != "" and state == "approved"

  @doc """
  The URL of the account's cached picture, or nil — which every surface renders
  as initials. Nil whenever the gate has not cleared it, so this is the one
  place the display rule lives.
  """
  def avatar_url(%__MODULE__{} = account) do
    if avatar_ready?(account),
      do: Vutuv.RemoteMedia.avatar_url(account.id, account.avatar)
  end

  @doc """
  The account's display name as vutuv writes it — its server's custom-emoji
  shortcodes taken out (`Vutuv.Fediverse.Handle.display_name/1`) — or nil where
  that leaves nothing. Beside `label/1` because the avatar's initials want the
  name alone and must not fall back to a handle.
  """
  def display_name(%__MODULE__{name: name}), do: Handle.display_name(name)

  @doc """
  What the account is called on screen: its display name, else the handle, else
  the bare actor URI. Never nil, so a row with no display fields still reads as
  something rather than as a gap.
  """
  def label(%__MODULE__{} = account) do
    display_name(account) || display_handle(account) || account.actor_uri
  end

  # The third identity kind the messages page can show (private messages to
  # and from another network), and exactly what `Vutuv.Identity` was written
  # for: a surface asks the identity instead of pattern-matching the party
  # columns again.
  #
  # Two answers differ from the local kinds on purpose. `path/1` points at the
  # account page here, not at a profile out there — a reader who taps a name
  # in their own inbox should land somewhere they can act (follow, mute,
  # write), with the origin one further click away. And `hidden?`/`indexable?`
  # are always true/false: this is somebody else's identity on somebody else's
  # server, so nothing here is ours to publish or to have crawled.
  defimpl Vutuv.Identity, for: Vutuv.Fediverse.RemoteAccount do
    alias Vutuv.Fediverse.Handle
    alias Vutuv.Fediverse.RemoteAccount

    def kind(_account), do: :remote_account

    def id(account), do: account.id

    def display_name(account), do: RemoteAccount.label(account)

    # The `@`-less full address, through the one module that owns how an
    # account is written (`Vutuv.Fediverse.Handle`): a bare "alice" would name
    # a different person on every server, and hand-composing it here would drop
    # the fallbacks a server that omits `preferredUsername` needs — leaving a
    # nil where a page then prints "@ wants to message you."
    def handle(account) do
      account
      |> RemoteAccount.display_handle()
      |> Handle.address()
    end

    def path(account), do: "/system/fediverse/account/#{account.id}"

    def image(account), do: account.avatar

    def hidden?(_account), do: true

    def indexable?(_account), do: false

    def topic(account), do: "fediverse_account:#{account.id}"

    def ap_type(_account), do: "Person"

    # The shape the local kinds publish (name, handle, absolute URL of `path/1`),
    # because it ships to clients through `VutuvWeb.AgentDocs.person_ref/1` and
    # a second shape there is a second thing to parse. The origin is one click
    # on from that page.
    def ref(account) do
      %{
        name: RemoteAccount.label(account),
        handle: handle(account),
        url: VutuvWeb.Endpoint.url() <> path(account)
      }
    end
  end
end
