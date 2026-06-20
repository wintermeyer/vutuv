defmodule Vutuv.ConnectionsTest do
  @moduledoc """
  Vernetzt (connected) = a mutual follow, derived from `follows` — there is no
  request/accept/decline flow any more. Plus the per-follow mute flag.
  """
  use Vutuv.DataCase

  alias Vutuv.Social

  defp users, do: {insert(:user, first_name: "Ann"), insert(:user, first_name: "Bob")}

  describe "connected?/2 (mutual follow)" do
    test "is false for a one-way follow, true once it is mutual, false after unfollow" do
      {a, b} = users()

      follow!(a, b)
      refute Social.connected?(a.id, b.id)

      follow!(b, a)
      assert Social.connected?(a.id, b.id)
      assert Social.connected?(b.id, a.id)

      fid = Social.follow_id(a.id, b.id)
      Social.unfollow!(a.id, fid)
      refute Social.connected?(a.id, b.id)
    end
  end

  describe "follow/2 fires the right event" do
    test "a one-way follow notifies the followee as a new follower" do
      {a, b} = users()
      Vutuv.Activity.subscribe(b.id)

      assert {:ok, _} = Social.follow(a, b.id)
      assert_receive {:new_notification, %{kind: "follower", actor_name: "Ann Test"}}
    end

    test "a follow-back that completes a mutual follow announces the connection" do
      {a, b} = users()
      # a already follows b; b follows back → they are now vernetzt.
      follow!(a, b)
      Vutuv.Activity.subscribe(a.id)

      assert {:ok, _} = Social.follow(b, a.id)
      assert Social.connected?(a.id, b.id)
      assert_receive {:new_notification, %{kind: "connection", actor_name: "Bob Test"}}
      # Not a plain new-follower event in this case.
      refute_received {:new_notification, %{kind: "follower"}}
    end
  end

  describe "list_connections/1 + connection_count/1" do
    test "list and count only the mutual, visible counterparties" do
      a = insert(:user, first_name: "Ann", email_confirmed?: true)
      mutual = insert(:user, first_name: "Bob", email_confirmed?: true)
      one_way = insert(:user, first_name: "Cy", email_confirmed?: true)

      # a <-> mutual; a -> one_way only (not connected)
      connect!(a, mutual)
      follow!(a, one_way)

      assert [%{user: u, follow_id: fid, muted?: false}] = Social.list_connections(a)
      assert u.id == mutual.id
      assert is_binary(fid)
      assert Social.connection_count(a) == 1
    end

    test "hides a counterparty hidden by moderation (no dead links)" do
      a = insert(:user, email_confirmed?: true)
      buddy = insert(:user, email_confirmed?: true)
      connect!(a, buddy)

      assert Social.connection_count(a) == 1

      buddy |> Ecto.Changeset.change(frozen_at: ~N[2026-01-01 00:00:00]) |> Repo.update!()

      assert Social.list_connections(a) == []
      assert Social.connection_count(a) == 0
    end
  end

  describe "toggle_follow_mute!/2" do
    test "flips the muted flag on the caller's own follow" do
      {a, b} = users()
      {:ok, follow} = Social.follow(a, b.id)
      refute follow.muted

      muted = Social.toggle_follow_mute!(a.id, follow.id)
      assert muted.muted
      assert Social.follow_edge(a.id, b.id).muted?

      unmuted = Social.toggle_follow_mute!(a.id, follow.id)
      refute unmuted.muted
    end

    test "is scoped to the follower (cannot mute someone else's follow)" do
      {a, b} = users()
      {:ok, follow} = Social.follow(a, b.id)
      stranger = insert(:user)

      assert_raise Ecto.NoResultsError, fn ->
        Social.toggle_follow_mute!(stranger.id, follow.id)
      end
    end

    test "muting keeps the relationship and any vernetzt status" do
      {a, b} = users()
      connect!(a, b)
      fid = Social.follow_id(a.id, b.id)

      Social.toggle_follow_mute!(a.id, fid)

      assert Social.user_follows_user?(a.id, b.id)
      assert Social.connected?(a.id, b.id)
    end
  end
end
