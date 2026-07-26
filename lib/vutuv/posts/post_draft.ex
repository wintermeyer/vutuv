defmodule Vutuv.Posts.PostDraft do
  @moduledoc """
  What the composer is holding but nobody has posted yet (issue #1148).

  A reload used to empty the composer, because LiveView's form recovery only
  runs on a socket *reconnect* while a reload rebuilds the page from nothing.
  So `VutuvWeb.PostLive.Composer` writes its content here as the member types
  and reads it back when it opens — the warning dialog the first attempt put in
  the way is gone, since there is no longer anything to warn about.

  The row mirrors the composer's own fields, not a post: `body` and `tags` are
  the raw, unparsed strings the form holds (tags become real tags on save), the
  `review` map is the book/film panel's form values, and `image_ids` names the
  still-pending `post_images` rows in the author's chosen order — the first one
  leads the mosaic, so the order is the layout and an array keeps it.

  **A draft belongs to a composer context**, carried by the two nullable
  references: both nil is the feed's new-post composer, `parent_id` is a reply
  to that post, `remote_note_id` an answer to a reply from another network.
  The edit page deliberately has no draft: its composer opens full of a
  *published* post, and quietly restoring a weeks-old unsaved edit over text
  other people have already read is a different and much less welcome promise.

  Nothing here is trusted on restore. `Vutuv.Posts.pending_images/2` re-checks
  every image id against the author's own unattached rows, so a stale or
  tampered list can neither steal a photo nor bring a removed one back, and the
  post changeset validates body, tags and review on save exactly as it does for
  a composer that was never reloaded.
  """

  use VutuvWeb, :model

  alias Vutuv.Posts.Post

  # Generous next to the handful of tags a post may carry, but bounded: the
  # field is raw text the member types, not the parsed tag list.
  @max_tags_length 2_000

  # The `mode` column of the composer's retired Text/Fotos tabs still exists
  # in the table (it has a DB default, so inserts stay fine); it is unused
  # since the tabs went and gets dropped in a later deploy (N-1 rule).
  schema "post_drafts" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:parent, Post)
    belongs_to(:remote_note, Vutuv.Fediverse.Note)

    field(:body, :string, default: "")
    field(:tags, :string, default: "")
    field(:license, :string)
    field(:review, :map, default: %{})
    field(:image_ids, {:array, :binary_id}, default: [])
    field(:photos, :map, default: %{})

    timestamps()
  end

  @doc """
  The changeset for one autosave.

  The length caps mirror the post's own, so a draft can never hold something
  the post would refuse anyway — and, more to the point, a background write
  must never raise: `body` and `tags` are `text` columns, but an unbounded
  paste would still be a surprise in the export and in every later read.
  `Vutuv.Posts.save_draft/3` treats an invalid changeset as "skip this
  autosave" rather than as an error the member has to see.
  """
  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:body, :tags, :license, :review, :image_ids, :photos])
    |> validate_length(:body, max: Post.max_body_length())
    |> validate_length(:tags, max: @max_tags_length)
  end

  @doc "The raw tag line's cap, so the composer and the tests agree on it."
  def max_tags_length, do: @max_tags_length

  @doc "Whether this draft holds anything worth restoring."
  def any_content?(%__MODULE__{} = draft) do
    String.trim(draft.body) != "" or String.trim(draft.tags) != "" or
      draft.image_ids != [] or review_kind(draft) != ""
  end

  defp review_kind(%__MODULE__{review: review}) when is_map(review),
    do: Map.get(review, "kind", "")

  defp review_kind(_draft), do: ""
end
