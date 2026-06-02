defmodule Vutuv.Social do
  @moduledoc """
  The Social context. Handles connections (follow/unfollow),
  groups, and memberships.
  """

  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.Social.Connection
  alias Vutuv.Social.Group
  alias Vutuv.Social.Membership

  # ── Connections ──

  def follow(follower_id, followee_id) do
    %Connection{}
    |> Connection.changeset(%{follower_id: follower_id, followee_id: followee_id})
    |> Repo.insert()
  end

  def unfollow!(connection_id) do
    Repo.get!(Connection, connection_id)
    |> Repo.delete!()
  end

  def get_connection!(id), do: Repo.get!(Connection, id)

  def follower_count(user) do
    Repo.one(
      from(c in Connection,
        where: c.followee_id == ^user.id,
        select: count(c.id)
      )
    )
  end

  def followee_count(user) do
    Repo.one(
      from(c in Connection,
        where: c.follower_id == ^user.id,
        select: count(c.id)
      )
    )
  end

  def user_follows_user?(follower_id, followee_id) do
    Repo.one(
      from(c in Connection,
        where: c.follower_id == ^follower_id and c.followee_id == ^followee_id,
        select: count(c.id)
      )
    ) > 0
  end

  # ── Groups ──

  def list_groups(user) do
    Repo.all(Ecto.assoc(user, :groups))
  end

  def get_group!(id), do: Repo.get!(Group, id)

  def create_group(user, attrs) do
    user
    |> Ecto.build_assoc(:groups)
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  def update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
  end

  def delete_group!(%Group{} = group), do: Repo.delete!(group)

  # ── Memberships ──

  def get_membership!(id), do: Repo.get!(Membership, id)

  def create_membership(attrs) do
    %Membership{}
    |> Membership.changeset(attrs)
    |> Repo.insert()
  end

  def delete_membership!(%Membership{} = membership), do: Repo.delete!(membership)
end
