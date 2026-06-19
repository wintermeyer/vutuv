defmodule Vutuv.Tags do
  @moduledoc """
  The Tags context: adding tags to users (one name or a comma-separated
  batch — registration and the tags page share this path) and user tag
  endorsements.
  """

  import Ecto.Query

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

  @doc """
  Removes `user_id`'s endorsement of `user_tag_id`. Returns the number of rows
  deleted (0 or 1), so an undo of an endorsement that is already gone is a
  no-op rather than a raise (the profile's upvote pill toggles idempotently).
  """
  def delete_endorsement(user_tag_id, user_id) do
    {count, _} =
      from(e in UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id and e.user_id == ^user_id
      )
      |> Repo.delete_all()

    count
  end

  @doc "Whether `user_id` currently endorses `user_tag_id`."
  def endorsed?(user_tag_id, user_id) do
    Repo.exists?(
      from(e in UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id and e.user_id == ^user_id
      )
    )
  end

  @doc """
  Number of *currently-visible* endorsers of `user_tag_id` (the public count
  shown on the upvote pill). Goes through `UserTagEndorsement.visible/1`, so a
  hidden or never-activated endorser never inflates the tally (issue #783).
  """
  def count_visible_endorsements(user_tag_id) do
    UserTagEndorsement.visible()
    |> where([e], e.user_tag_id == ^user_tag_id)
    |> Repo.aggregate(:count)
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
