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

  @doc """
  Deletes a follow edge. The lookup is scoped to `follower_id`, so a caller can
  only remove their own connections, never an arbitrary one by id.
  """
  def unfollow!(follower_id, connection_id) do
    Repo.get_by!(Connection, id: connection_id, follower_id: follower_id)
    |> Repo.delete!()
  end

  def list_connections do
    Connection
    |> Repo.all()
    |> Repo.preload([:follower, :followee])
  end

  def get_connection!(id, preloads \\ []) do
    Repo.get!(Connection, id) |> Repo.preload(preloads)
  end

  # The public pages only count/show follows from validated accounts (nil
  # covers legacy rows that predate the flag), matching Connection.latest/1.

  def follower_count(user) do
    Repo.one(
      from(c in Connection,
        join: u in assoc(c, :follower),
        where: (is_nil(u.validated?) or u.validated? == true) and c.followee_id == ^user.id,
        select: count(c.id)
      )
    )
  end

  def followee_count(user) do
    Repo.one(
      from(c in Connection,
        join: u in assoc(c, :followee),
        where: (is_nil(u.validated?) or u.validated? == true) and c.follower_id == ^user.id,
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

  @doc """
  The id of the `follower → followee` connection, or `nil` when there is no
  follow edge. Templates use the id to render the unfollow link.
  """
  def follow_connection_id(follower_id, followee_id) do
    Repo.one(
      from(c in Connection,
        where: c.follower_id == ^follower_id and c.followee_id == ^followee_id,
        select: c.id
      )
    )
  end

  @doc """
  The `limit` users with the most followers, ties broken by name. Backs both
  the public listing page and the profile's default "who to follow" rail.
  """
  def most_followed_users(limit) do
    Repo.all(
      from(u in Vutuv.Accounts.User,
        left_join: f in assoc(u, :followers),
        group_by: u.id,
        order_by: [fragment("count(?) DESC", f.id), u.first_name, u.last_name],
        limit: ^limit
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

  @doc """
  Fetches a membership scoped to `connection`, so a caller can only reach
  memberships of a connection they actually own.
  """
  def get_membership!(%Connection{} = connection, id) do
    Repo.get!(Ecto.assoc(connection, :memberships), id)
  end

  def create_membership(%Connection{} = connection, attrs) do
    connection
    |> Ecto.build_assoc(:memberships)
    |> Membership.changeset(attrs)
    |> Repo.insert()
  end

  def delete_membership!(%Membership{} = membership), do: Repo.delete!(membership)
end
