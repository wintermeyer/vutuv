defmodule Vutuv.Posts.PendingPost do
  @moduledoc """
  A post that waits for its media (issues #1910, #2106).

  A photo post publishes at once and its pictures catch up pixelated (#1720);
  a text whose clip or whose files are missing reads as broken, so a post that
  carries either is not a post until the server is done with them. Rather than
  a hidden `posts` row — which every feed, profile and archive query would
  have to learn to filter — the composer's submission is stored here as a job:
  the create path it took (`kind`), the context that path needs, and the attrs
  verbatim. `Vutuv.Posts.Publisher` turns the row into a real post through the
  very `Vutuv.Posts.create_*` function the composer would have called, the
  moment the last medium is done.

  ## What it waits for

  The clip is one case, not the shape. A row names its clip through `video_id`
  and its files through `attachments.pending_post_id` (a file is one of up to
  five, so the pointer sits on the file), and it is ready when **all** of them
  are: the clip converted and checked, every file rendered, every preview page
  the render produced past the AI check. `Vutuv.Posts.Pending.state/1` is the
  one place that asks.

  A refused or broken medium does not lose the text: the row stays `waiting`
  with the verdict on it, and the author's card offers to publish without the
  refused medium or to drop the whole thing.

  ## Surviving a deploy

  `status` is the state, and it lives on the row rather than in the process
  that is publishing: `waiting` → `publishing` (a compare-and-set, so two
  slots of a blue/green overlap cannot publish the same text) → `published`,
  `failed` or `canceled`. `minted_post_id` is the post's id, minted *before*
  the create path runs and written with the claim, so a slot killed between
  the insert and the bookkeeping is resumed by finding the post that already
  exists instead of writing the member's post a second time.
  """

  use VutuvWeb, :model

  @kinds ~w(post reply organization_post remote_reply remote_post_reply)

  schema "pending_posts" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:video, Vutuv.Posts.PostVideo)
    has_many(:attachments, Vutuv.Attachments.Attachment, foreign_key: :pending_post_id)

    field(:kind, :string)
    belongs_to(:parent_post, Vutuv.Posts.Post)
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:note, Vutuv.Fediverse.Note)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    field(:attrs, :map, default: %{})

    field(:status, :string, default: "waiting")
    belongs_to(:post, Vutuv.Posts.Post)
    field(:minted_post_id, Vutuv.UUIDv7)
    field(:error, :string)

    # The scheduler's clock: when the sweeper last looked at this row, whatever
    # it found. Not "when work happened" — see `Vutuv.Posts.Pending.due/1`.
    field(:checked_at, :utc_datetime)

    timestamps()
  end

  def changeset(pending, params) do
    pending
    |> cast(params, [:kind, :parent_post_id, :organization_id, :note_id, :remote_post_id, :attrs])
    |> validate_required([:kind, :attrs])
    |> validate_inclusion(:kind, @kinds)
  end

  @doc "The create paths a waiting post can take."
  def kinds, do: @kinds

  @doc "Whether this row is still on its way somewhere."
  def open?(%__MODULE__{status: status}), do: status in ~w(waiting publishing)
end
