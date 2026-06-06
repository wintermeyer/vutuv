defmodule Vutuv.Posts.PostTag do
  @moduledoc false

  use VutuvWeb, :model

  schema "post_tags" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  def changeset(post_tag, params \\ %{}) do
    post_tag
    |> cast(params, [:tag_id])
    |> validate_required([:tag_id])
    |> unique_constraint(:tag_id, name: :post_tags_post_id_tag_id_index)
  end
end
