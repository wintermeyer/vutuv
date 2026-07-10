defmodule Vutuv.Posts.Post do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.MarkdownContent

  @max_body_length 20_000

  schema "posts" do
    field(:body, :string, default: "")
    # The archive coordinate (/:slug/posts/2026/06/06): the UTC date at
    # insert time, set programmatically, never cast from params. The
    # permalink itself is the post id (a UUID v7).
    field(:published_on, :date)
    # Set while the post is in the moderation freezer: hidden from everyone
    # but the author and admins. Managed by Vutuv.Moderation, never cast.
    field(:frozen_at, :naive_datetime)
    # Postgres-generated tsvector over body (see the migration); referenced
    # only by search_public/2's fragments, never loaded or written by Ecto.
    field(:search_tsv, :string, load_in_query: false)

    belongs_to(:user, Vutuv.Accounts.User)

    # Present iff this post is a reply; survives parent deletion (see PostReply).
    has_one(:reply_ref, Vutuv.Posts.PostReply, foreign_key: :post_id)

    has_many(:denials, Vutuv.Posts.PostDenial, on_replace: :delete)
    has_many(:images, Vutuv.Posts.PostImage, preload_order: [asc: :position])

    # The auto-generated link screenshot: present iff this post carried a single
    # URL and no image at save time (see Vutuv.Posts.Screenshots). Rendered
    # beside the body once `status: "ready"`.
    has_one(:screenshot, Vutuv.Posts.PostScreenshot)
    has_many(:post_tags, Vutuv.Posts.PostTag, on_replace: :delete)
    has_many(:tags, through: [:post_tags, :tag])

    timestamps()
  end

  def max_body_length, do: @max_body_length

  def changeset(post, params \\ %{}) do
    post
    # empty_values: [] so clearing the body on edit is a real change ("" must
    # not be swallowed as "no change") — a photo-only post has an empty body.
    |> cast(params, [:body], empty_values: [])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, max: @max_body_length)
    # Post bodies never embed images: uploaded pictures are attachments shown as
    # a gallery, not inline in the prose. The renderer also drops any `<img>` at
    # display time (`VutuvWeb.Markdown.render_post/2`); this is the storage guard.
    |> MarkdownContent.validate_no_images()
  end
end
