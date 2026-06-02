defmodule Vutuv.Tags.UserTagEndorsement do
  @moduledoc false

  use VutuvWeb, :model

  schema "user_tag_endorsements" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:user_tag, Vutuv.Tags.UserTag)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:user_id, :user_tag_id])
    |> unique_constraint(:user_id_user_tag_id)
  end

  def count(user_tag_id) do
    Vutuv.Repo.one!(
      from(e in Vutuv.Tags.UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id,
        select: count("*")
      )
    )
  end

  def tag_endorsed?(user_tag_id, user_id) do
    Vutuv.Repo.one!(
      from(e in Vutuv.Tags.UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id and e.user_id == ^user_id,
        select: count("*")
      )
    ) > 0
  end
end
