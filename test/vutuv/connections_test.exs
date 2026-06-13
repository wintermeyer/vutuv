defmodule Vutuv.ConnectionsTest do
  @moduledoc """
  The mutual, consented connection lifecycle: request → accept | decline,
  the mutual-desire auto-accept, the re-request cooldown, and the follow edges
  acceptance materializes.
  """
  use Vutuv.DataCase

  alias Vutuv.Social
  alias Vutuv.Social.Connection

  defp users, do: {insert(:user, first_name: "Ann"), insert(:user, first_name: "Bob")}

  describe "request_connection/2" do
    test "opens a pending request and notifies the recipient" do
      {a, b} = users()
      Vutuv.Activity.subscribe(b.id)

      assert {:ok, %Connection{} = c} = Social.request_connection(a, b)
      assert c.status == "pending"
      assert c.requested_by_id == a.id
      # Stored sorted regardless of who asked.
      assert {c.user_a_id, c.user_b_id} == Enum.min_max([a.id, b.id])

      assert_receive {:new_notification, %{kind: "connection_request", actor_name: "Ann Test"}}
    end

    test "is canonical: arg order does not create a second row" do
      {a, b} = users()
      assert {:ok, _} = Social.request_connection(a, b)
      assert {:error, :already_requested} = Social.request_connection(a, b)
      assert Repo.aggregate(Connection, :count) == 1
    end

    test "rejects connecting to yourself" do
      {a, _b} = users()
      assert {:error, :self} = Social.request_connection(a, a)
    end

    test "a request to someone who already asked me auto-accepts (mutual desire)" do
      {a, b} = users()
      assert {:ok, _pending} = Social.request_connection(a, b)

      Vutuv.Activity.subscribe(a.id)
      assert {:ok, %Connection{status: "accepted"}} = Social.request_connection(b, a)

      assert Social.connected?(a.id, b.id)
      # Acceptance materializes the follow both ways.
      assert Social.user_follows_user?(a.id, b.id)
      assert Social.user_follows_user?(b.id, a.id)
      # The original requester learns it was accepted.
      assert_receive {:new_notification, %{kind: "connection_accepted", actor_name: "Bob Test"}}
    end

    test "rejects a duplicate request when already connected" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)
      {:ok, _} = Social.accept_connection(b, c.id)

      assert {:error, :already_connected} = Social.request_connection(a, b)
    end
  end

  describe "accept_connection/2" do
    test "the recipient accepts: follows both ways + notifies the requester" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)

      Vutuv.Activity.subscribe(a.id)
      assert {:ok, %Connection{status: "accepted"}} = Social.accept_connection(b, c.id)

      assert Social.connected?(a.id, b.id)
      assert Social.user_follows_user?(a.id, b.id)
      assert Social.user_follows_user?(b.id, a.id)
      assert_receive {:new_notification, %{kind: "connection_accepted", actor_name: "Bob Test"}}
    end

    test "the requester cannot accept their own request" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)

      assert {:error, :not_found} = Social.accept_connection(a, c.id)
      refute Social.connected?(a.id, b.id)
    end

    test "acceptance is idempotent with a pre-existing one-way follow" do
      {a, b} = users()
      follow!(a, b)
      {:ok, c} = Social.request_connection(a, b)

      assert {:ok, _} = Social.accept_connection(b, c.id)
      assert Social.user_follows_user?(a.id, b.id)
      assert Social.user_follows_user?(b.id, a.id)
    end

    test "a garbage id is not found, not a crash" do
      {_a, b} = users()
      assert {:error, :not_found} = Social.accept_connection(b, "not-a-uuid")
    end
  end

  describe "decline_connection/2 + cooldown" do
    test "declining is silent and blocks the requester until the cooldown elapses" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)

      Vutuv.Activity.subscribe(a.id)
      assert {:ok, %Connection{status: "declined"}} = Social.decline_connection(b, c.id)
      # Silent: the requester is not told.
      refute_receive {:new_notification, %{kind: "connection_declined"}}

      assert {:error, :cooldown} = Social.request_connection(a, b)
    end

    test "the requester may retry once the cooldown has elapsed" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)
      {:ok, _} = Social.decline_connection(b, c.id)
      backdate_status(c, -(Social.request_cooldown_days() + 1) * 24 * 3600)

      assert {:ok, %Connection{status: "pending", requested_by_id: req}} =
               Social.request_connection(a, b)

      assert req == a.id
    end

    test "the party who declined may request in the other direction immediately" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)
      {:ok, _} = Social.decline_connection(b, c.id)

      # b (who declined a) now wants to connect with a — a fresh request, no cooldown.
      assert {:ok, %Connection{status: "pending", requested_by_id: req}} =
               Social.request_connection(b, a)

      assert req == b.id
    end

    test "tells the decliner's shell to recompute its notification badge (#782)" do
      # The recipient's pending-request notification disappears on decline, but
      # nothing used to tell their shell, so the bell badge stayed stale until a
      # reload. The decliner (b) now gets a :notifications_changed nudge.
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)

      Vutuv.Activity.subscribe(a.id)
      Vutuv.Activity.subscribe(b.id)
      {:ok, _} = Social.decline_connection(b, c.id)

      assert_receive :notifications_changed
      # Silent toward the requester: a is not nudged (and never learns of the decline).
      refute_received :notifications_changed
    end
  end

  describe "remove_connection/2" do
    test "disconnecting deletes the connection but keeps the follow edges" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)
      {:ok, _} = Social.accept_connection(b, c.id)

      assert {:ok, _} = Social.remove_connection(a, c.id)
      refute Social.connected?(a.id, b.id)
      # Follows are independent and survive the disconnect.
      assert Social.user_follows_user?(a.id, b.id)
      assert Social.user_follows_user?(b.id, a.id)
    end

    test "withdraws an outgoing pending request" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)

      assert {:ok, _} = Social.remove_connection(a, c.id)
      assert %{status: :none} = Social.connection_state(a, b)
    end

    test "withdrawing nudges both parties' shells to recompute the badge (#782)" do
      # The recipient (b) had a pending-request notification; withdrawing it must
      # drop their badge. remove_connection broadcasts :notifications_changed to
      # both parties so each shell recomputes from the source of truth (it is a
      # harmless no-op for the requester, whose count never included the request).
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)

      Vutuv.Activity.subscribe(a.id)
      Vutuv.Activity.subscribe(b.id)
      assert {:ok, _} = Social.remove_connection(a, c.id)

      assert_receive :notifications_changed
      assert_receive :notifications_changed
      refute_received :notifications_changed
    end

    test "a non-party cannot remove it" do
      {a, b} = users()
      stranger = insert(:user)
      {:ok, c} = Social.request_connection(a, b)

      assert {:error, :not_found} = Social.remove_connection(stranger, c.id)
    end
  end

  describe "connection_state/2" do
    test "reflects each side of the lifecycle" do
      {a, b} = users()
      assert %{status: :none} = Social.connection_state(a, b)

      {:ok, c} = Social.request_connection(a, b)
      assert %{status: :pending_sent} = Social.connection_state(a, b)
      assert %{status: :pending_received} = Social.connection_state(b, a)

      {:ok, _} = Social.accept_connection(b, c.id)
      assert %{status: :accepted} = Social.connection_state(a, b)
      assert %{status: :accepted} = Social.connection_state(b, a)
    end

    test "a decline reads as spent to the requester, none to the decliner" do
      {a, b} = users()
      {:ok, c} = Social.request_connection(a, b)
      {:ok, _} = Social.decline_connection(b, c.id)

      assert %{status: :declined} = Social.connection_state(a, b)
      assert %{status: :none} = Social.connection_state(b, a)
    end
  end

  describe "listings + count" do
    test "lists connections, incoming and outgoing requests; counts accepted" do
      # Activated like every real connection participant (request/accept
      # require a login, which activates) — list_connections only shows
      # activated, non-hidden people.
      a = insert(:user, first_name: "Ann", activated?: true)
      b = insert(:user, first_name: "Bob", activated?: true)
      c2 = insert(:user, first_name: "Cy", activated?: true)
      d = insert(:user, first_name: "Di", activated?: true)

      # a connected with b
      connect!(a, b)
      # c2 asked a (incoming for a)
      {:ok, _} = Social.request_connection(c2, a)
      # a asked d (outgoing for a)
      {:ok, _} = Social.request_connection(a, d)

      assert [%{user: conn_user}] = Social.list_connections(a)
      assert conn_user.id == b.id
      assert Social.connection_count(a) == 1

      assert [%{user: inc}] = Social.list_incoming_requests(a)
      assert inc.id == c2.id

      assert [%{user: out}] = Social.list_outgoing_requests(a)
      assert out.id == d.id
    end

    test "request lists hide a counterparty hidden by moderation (no dead links)" do
      a = insert(:user, activated?: true)
      incoming = insert(:user, activated?: true)
      outgoing = insert(:user, activated?: true)

      {:ok, _} = Social.request_connection(incoming, a)
      {:ok, _} = Social.request_connection(a, outgoing)

      assert [_one] = Social.list_incoming_requests(a)
      assert [_one] = Social.list_outgoing_requests(a)

      # Both counterparties get frozen by moderation after requesting: their
      # profiles 404, so the request rows must drop out rather than link there.
      for u <- [incoming, outgoing] do
        u |> Ecto.Changeset.change(frozen_at: ~N[2026-01-01 00:00:00]) |> Repo.update!()
      end

      assert Social.list_incoming_requests(a) == []
      assert Social.list_outgoing_requests(a) == []
    end
  end

  defp backdate_status(%Connection{id: id}, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), seconds)
    Repo.update_all(from(c in Connection, where: c.id == ^id), set: [status_changed_at: at])
  end
end
