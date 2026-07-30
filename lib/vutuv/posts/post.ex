defmodule Vutuv.Posts.Post do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.MarkdownContent
  alias Vutuv.Mentions
  alias Vutuv.Posts.GalleryLayout
  alias Vutuv.Posts.PhotoLicense

  @max_body_length 20_000

  schema "posts" do
    field(:body, :string, default: "")

    # The bento arrangement the author picked for a multi-photo post, one of
    # the `Vutuv.Posts.GalleryLayout` names; nil = automatic (the mosaic's
    # orientation-driven choice). Presentation only — the agent formats list
    # the photos regardless of how the HTML tiles them.
    field(:gallery_layout, :string)
    # Whether the bento tiles are FILLED by their photos (object-cover, which
    # crops them to the tile). Default false: the mosaic shows whole photos,
    # letterboxed inside their tiles — nobody's picture loses its edges
    # without the author asking for it.
    field(:gallery_fill?, :boolean, default: false)

    # The license the post's photos are published under (issue #1104), from
    # the fixed `Vutuv.Posts.PhotoLicense` vocabulary. It rides on the post,
    # not the photo: a set of pictures posted together is one act of
    # publishing, and a per-photo licence picker would be a forest of selects
    # for a case nobody has.
    field(:license, :string, default: "arr")
    # The archive coordinate (/:slug/posts/2026/06/06): the UTC date at
    # insert time, set programmatically, never cast from params. The
    # permalink itself is the post id (a UUID v7).
    field(:published_on, :date)
    # Set while the post is in the moderation freezer: hidden from everyone
    # but the author and admins. Managed by Vutuv.Moderation, never cast.
    field(:frozen_at, :naive_datetime)

    # True while any attached photo is still waiting for the AI image scan
    # (issue #1104). Such a post is held back **whole** — out of every feed,
    # profile, permalink and the Fediverse — and visible to its author alone,
    # who sees it marked as not yet public. Denormalised from `images` so the
    # visibility scope stays a boolean test rather than a subquery in the
    # newsfeed's inner loop; `Vutuv.Posts.refresh_images_pending/1` owns it and
    # it is never cast from params.
    field(:images_pending?, :boolean, default: false)
    # Postgres-generated tsvector over body (see the migration); referenced
    # only by search_public/2's fragments, never loaded or written by Ecto.
    field(:search_tsv, :string, load_in_query: false)

    belongs_to(:user, Vutuv.Accounts.User)

    # Present iff this post is a reply; survives parent deletion (see PostReply).
    has_one(:reply_ref, Vutuv.Posts.PostReply, foreign_key: :post_id)

    # Present iff this reply also answers a reply from another network (issue
    # #1070). Rides alongside `reply_ref`, never instead of it, and carries its
    # own copy of the delivery target so it outlives the cached remote note.
    has_one(:remote_reply_ref, Vutuv.Posts.PostRemoteReply, foreign_key: :post_id)

    has_many(:denials, Vutuv.Posts.PostDenial, on_replace: :delete)
    has_many(:images, Vutuv.Posts.PostImage, preload_order: [asc: :position])

    # The auto-generated link screenshot: present iff this post carried a single
    # URL and no image at save time (see Vutuv.Posts.Screenshots). Rendered
    # beside the body once `status: "ready"`.
    has_one(:screenshot, Vutuv.Posts.PostScreenshot)

    # The structured book/film review riding on this post (see PostReview);
    # nil for ordinary posts. Replaced wholesale on edit, deleted when the
    # author clears the review kind.
    has_one(:review, Vutuv.Posts.PostReview, on_replace: :delete)

    has_many(:post_tags, Vutuv.Posts.PostTag, on_replace: :delete)
    has_many(:tags, through: [:post_tags, :tag])

    timestamps()
  end

  def max_body_length, do: @max_body_length

  def changeset(post, params \\ %{}) do
    post
    # empty_values: [] so clearing the body on edit is a real change ("" must
    # not be swallowed as "no change") — a photo-only post has an empty body.
    |> cast(params, [:body, :license, :gallery_layout, :gallery_fill?], empty_values: [])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, max: @max_body_length)
    # An unknown licence becomes the safe default rather than a validation
    # error: a tampered select must not be able to fail a post, and "all
    # rights reserved" is the answer that grants nothing.
    |> update_change(:license, &PhotoLicense.cast/1)
    # Same idea for the bento arrangement: an unknown name means "automatic"
    # (nil), never a failed post.
    |> update_change(:gallery_layout, &GalleryLayout.cast/1)
    # A post body may embed only its own uploaded images (`![](…)` with a
    # `/post_images/<token>/<version>` URL, optional alignment fragment) —
    # never a remote hotlink, which would leak every reader's IP. The renderer
    # enforces ownership at display time (`VutuvWeb.Markdown.render_post/2`
    # only inlines the post's own attachments); this is the storage guard.
    |> MarkdownContent.validate_own_images_only()
    # A body may only mention handles that exist, so nobody can seed `@wanted`
    # into a post to reserve it (the anti-hijack partner of handle availability).
    |> Mentions.validate_mentions_exist()
  end
end
