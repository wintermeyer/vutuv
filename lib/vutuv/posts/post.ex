defmodule Vutuv.Posts.Post do
  @moduledoc false

  use VutuvWeb, :model

  @max_body_length 20_000

  schema "posts" do
    field(:body, :string, default: "")
    # The permalink date/counter: /:slug/:year/:month/:day/:seq. Both are set
    # programmatically at insert time (UTC date + per-user-per-day counter),
    # never cast from params.
    field(:published_on, :date)
    field(:seq, :integer)

    belongs_to(:user, Vutuv.Accounts.User)

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
    |> unique_constraint(:seq, name: :posts_user_id_published_on_seq_index)
  end

  @doc ~S(The date-stamped human id, e.g. "2026-06-05-0001".)
  def slug(%__MODULE__{published_on: date, seq: seq}) do
    "#{Date.to_iso8601(date)}-#{seq_string(seq)}"
  end

  @doc "The zero-padded counter as it appears in the URL."
  def seq_string(seq), do: String.pad_leading(Integer.to_string(seq), 4, "0")
end
