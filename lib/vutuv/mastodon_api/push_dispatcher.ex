defmodule Vutuv.MastodonApi.PushDispatcher do
  @moduledoc """
  Turns a member's new notification into a Web Push, for every device that
  registered one.

  Hooked into `Vutuv.Activity.notify/2`, the one place a notification is
  announced, so a push cannot drift out of step with what the website shows.
  Sending is **fire and forget in a task**: a push service is somebody else's
  machine on the other side of the internet, and the member's own action —
  liking, following, replying — must not wait on it or fail with it.

  Only the kinds Mastodon has a type for are pushed, the same subset the REST
  endpoint serves; a device that asked not to hear about a kind (`alerts`) is
  skipped. A subscription the service reports as gone is deleted on the spot,
  which is how the list stays clean without a sweeper.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.ApiAuth.Token
  alias Vutuv.MastodonApi.Notifications
  alias Vutuv.MastodonApi.PushSubscription
  alias Vutuv.MastodonApi.WebPush
  alias Vutuv.Repo

  @doc "Pushes `notification` to `user_id`'s registered devices, if any."
  # **Nothing here touches the database on the caller's process.** `notify/2` is
  # the notification chokepoint, so this runs inside whatever action produced
  # the notification — often inside its transaction — and a member liking a post
  # should not wait on two reads that only a push service will ever care about.
  # The cheap decisions (is push configured at all, is this a kind Mastodon
  # knows) are made here because they cost no query and skip the task entirely;
  # everything that reads a row happens in the task.
  def dispatch(user_id, notification) when is_binary(user_id) do
    with true <- WebPush.configured?(),
         type when is_binary(type) <- Notifications.type(notification[:kind]) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
        fan_out(user_id, type, notification)
      end)
    end

    :ok
  end

  def dispatch(_user_id, _notification), do: :ok

  defp fan_out(user_id, type, notification) do
    case subscriptions_for(user_id, type) do
      [] -> :ok
      rows -> Enum.each(rows, fn {sub, locale} -> deliver(sub, type, notification, locale) end)
    end
  end

  # Joined to the token rather than selected on `user_id` alone: revoking a
  # credential marks it `revoked_at` instead of deleting it, so the
  # subscription's cascade never fires and a device the member signed out of
  # would keep being pushed to. `Vutuv.ApiAuth` deletes the row as well; this is
  # the check that cannot be forgotten by a revocation path added later.
  #
  # The member's locale rides along instead of costing a second `Repo.get`: it
  # is one value for one member, and the join that already has to happen can
  # carry it.
  defp subscriptions_for(user_id, type) do
    from(s in PushSubscription,
      join: t in Token,
      on: t.id == s.api_token_id,
      join: u in User,
      on: u.id == s.user_id,
      where: s.user_id == ^user_id and is_nil(t.revoked_at),
      select: {s, u.locale}
    )
    |> Repo.all()
    |> Enum.filter(fn {subscription, _locale} -> wants?(subscription, type) end)
    |> Enum.map(fn {subscription, locale} -> {subscription, locale(locale)} end)
  end

  defp wants?(%PushSubscription{alerts: alerts}, type), do: Map.get(alerts, type, true) == true

  # The member's own language, not a hardcoded "de": vutuv is installable by
  # third parties, and a client uses this to pick which of its own strings to
  # show beside the notification. A member who never chose falls back to the
  # same "en" `VutuvWeb.Plugs.Locale` falls back to, so the push and the website
  # cannot disagree about what language they think this person reads.
  @fallback_locale "en"

  defp locale(value) when is_binary(value) and value != "", do: value
  defp locale(_no_choice), do: @fallback_locale

  defp deliver(subscription, type, notification, locale) do
    # No content: the payload says what kind of thing happened and which
    # notification it was, never a word of what was written. The client fetches
    # the rest over the authenticated API, where the reader is known.
    payload = %{
      notification_id: notification[:id],
      notification_type: type,
      preferred_locale: locale,
      title: nil,
      body: nil
    }

    Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
      case WebPush.send(subscription, payload) do
        :ok ->
          :ok

        {:error, :gone} ->
          Repo.delete(subscription)

        {:error, reason} ->
          Logger.warning("web push failed: #{inspect(reason)}")
      end
    end)
  end
end
