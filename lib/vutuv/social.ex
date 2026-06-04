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

  @doc """
  Follow a user. `follower` is a `%Vutuv.Accounts.User{}` or an id — callers
  that already hold the session user struct pass it directly, which saves the
  `Repo.get` otherwise needed to build the live new-follower notification.
  """
  def follow(follower, followee_id) do
    result =
      %Connection{}
      |> Connection.changeset(%{follower_id: follower_id(follower), followee_id: followee_id})
      |> Repo.insert()

    with {:ok, _connection} <- result do
      follower = follower_struct(follower)
      Vutuv.Activity.notify_new_follower(followee_id, follower)

      # A follow-back turns the pair into a mutual connection - tell both.
      if user_follows_user?(followee_id, follower.id) do
        followee = Repo.get(Vutuv.Accounts.User, followee_id)
        Vutuv.Activity.notify_connection(follower.id, followee)
        Vutuv.Activity.notify_connection(followee_id, follower)
      end
    end

    result
  end

  defp follower_id(%Vutuv.Accounts.User{id: id}), do: id
  defp follower_id(id), do: id

  defp follower_struct(%Vutuv.Accounts.User{} = user), do: user
  defp follower_struct(id), do: Repo.get(Vutuv.Accounts.User, id)

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
    Repo.exists?(
      from(c in Connection,
        where: c.follower_id == ^follower_id and c.followee_id == ^followee_id
      )
    )
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
