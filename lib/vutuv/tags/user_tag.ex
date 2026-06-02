defmodule Vutuv.Tags.UserTag do
  @moduledoc false

  use VutuvWeb, :model

  schema "user_tags" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:tag, Vutuv.Tags.Tag)

    has_many(:endorsements, Vutuv.Tags.UserTagEndorsement)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:user_id, :tag_id])
    |> unique_constraint(:user_id_tag_id, message: "You already have this tag.")
  end

  def name(user_tag) do
    user_tag = Vutuv.Repo.preload(user_tag, :tag)
    user_tag.tag.name
  end

  def truncated_name(user_tag) do
    tag_name = name(user_tag)

    truncated_tag_name =
      tag_name
      |> String.slice(0..50)

    if truncated_tag_name == tag_name do
      tag_name
    else
      truncated_tag_name <> " ..."
    end
  end

  defimpl Phoenix.Param, for: Vutuv.Tags.UserTag do
    def to_param(user_tag) do
      Vutuv.Repo.preload(user_tag, [:tag]).tag.slug
    end
  end
end
