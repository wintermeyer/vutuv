defmodule Vutuv.Posts.Post do
  @moduledoc false

  use VutuvWeb, :model

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

    belongs_to(:user, Vutuv.Accounts.User)

    # Present iff this post is a reply; survives parent deletion (see PostReply).
    has_one(:reply_ref, Vutuv.Posts.PostReply, foreign_key: :post_id)

    has_many(:denials, Vutuv.Posts.PostDenial, on_replace: :delete)
    has_many(:images, Vutuv.Posts.PostImage, preload_order: [asc: :position])
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
  end
end
