defmodule Vutuv.Tags do
  @moduledoc """
  The Tags context: adding tags to users (one name or a comma-separated
  batch — registration and the tags page share this path) and user tag
  endorsements.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement

  @doc """
  Splits a comma-separated tag string into clean names: `" PHP, , Go "` →
  `["PHP", "Go"]`. Safe to call with `nil` (returns `[]`).
  """
  def parse_tag_names(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_tag_names(_), do: []

  @doc """
  Tags `user` with `name`, creating the global tag or linking the existing
  one. Returns the `Repo.insert` result; a duplicate or invalid name comes
  back as `{:error, changeset}`.
  """
  def add_user_tag(%User{} = user, name) when is_binary(name) do
    user
    |> Ecto.build_assoc(:user_tags, %{})
    |> UserTag.changeset()
    |> Tag.create_or_link_tag(%{"value" => name})
    |> Repo.insert()
  end

  @doc """
  Endorse a user's tag. The chokepoint for endorsements: besides inserting the
  row it pushes the live in-app notification to the tag's owner, so all
  endorsement paths must come through here (not a raw `Repo.insert`).
  """
  def create_endorsement(attrs) do
    result = %UserTagEndorsement{} |> UserTagEndorsement.changeset(attrs) |> Repo.insert()

    with {:ok, endorsement} <- result do
      notify_endorsement(endorsement)
    end

    result
  end

  defp notify_endorsement(endorsement) do
    %{user_tag: %{user_id: owner_id, tag: tag}} =
      Repo.preload(endorsement, user_tag: :tag)

    # Endorsing your own tag is possible but not news.
    if owner_id != endorsement.user_id do
      endorser = Repo.get(Vutuv.Accounts.User, endorsement.user_id)
      Vutuv.Activity.notify_endorsement(owner_id, endorser, tag.name)
    end
  end
end
