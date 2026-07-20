defmodule Vutuv.Posts.Post do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.MarkdownContent
  alias Vutuv.Mentions

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
