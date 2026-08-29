defmodule Vutuv.WebPush.Subscriptions do
  @moduledoc """
  The devices a member asked to be woken on when vutuv is closed (issue #1729).

  A subscription belongs to a **browser**, not to an account: it is the address
  that browser's push service handed out, and it keeps working after the tab is
  gone, which is the whole point. So the per-account "browser notifications"
  preference cannot answer for it — a member switches the account preference on
  once and then says "also when vutuv is closed" per phone, and that answer is
  the presence or absence of a row here.
  """

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Repo
  alias Vutuv.WebPush.Subscription

  @doc """
  Stores (or moves) the subscription `endpoint` belongs to.

  Keyed on the endpoint, so the same browser signing in as somebody else moves
  the row rather than leaving the previous member's pushes going to a device
  they signed out of. The keys are re-written too: a browser may hand out the
  same endpoint with a fresh key pair after it re-subscribes.
  """
  def subscribe(user_id, attrs, device) when is_binary(user_id) do
    %Subscription{user_id: user_id}
    |> Subscription.changeset(Map.put(attrs, "device", device))
    |> Repo.insert(
      on_conflict: {:replace, [:user_id, :p256dh, :auth, :device, :updated_at]},
      conflict_target: :endpoint
    )
  end

  @doc """
  Forgets one endpoint, whoever it belongs to.

  Not scoped to the member: an endpoint is a browser, and the browser saying
  "stop" (a sign-out, a switched-off device toggle, a push service reporting
  the subscription gone) is the authority on that. Nothing here is readable, so
  there is nothing for a guessed endpoint to disclose — and a member cannot
  reach another one's endpoint without already knowing it.
  """
  def unsubscribe(endpoint) when is_binary(endpoint) do
    Repo.delete_all(from(s in Subscription, where: s.endpoint == ^endpoint))
    :ok
  end

  @doc "Forgets one of the member's own devices, by id — the settings list's row action."
  def delete(user_id, id) when is_binary(user_id) and is_binary(id) do
    Repo.delete_all(from(s in Subscription, where: s.user_id == ^user_id and s.id == ^id))
    :ok
  end

  @doc "This member's registered devices, newest first."
  def for_user(user_id) when is_binary(user_id) do
    Repo.all(from(s in Subscription, where: s.user_id == ^user_id, order_by: [desc: s.id]))
  end
end
