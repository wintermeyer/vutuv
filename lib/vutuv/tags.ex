defmodule Vutuv.Tags do
  @moduledoc """
  The Tags context. Handles user tag endorsements; tags and user tags are
  managed by the controllers through their schema modules directly.
  """

  alias Vutuv.Repo
  alias Vutuv.Tags.UserTagEndorsement

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
