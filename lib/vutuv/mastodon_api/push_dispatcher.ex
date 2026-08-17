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

  import Ecto.Query, only: [where: 3]

  require Logger

  alias Vutuv.MastodonApi.PushSubscription
  alias Vutuv.MastodonApi.WebPush
  alias Vutuv.Repo

  @types %{
    "mention" => "mention",
    "reply" => "mention",
    "thread" => "mention",
    "fediverse_reply" => "mention",
    "like" => "favourite",
    "fediverse_reaction" => "favourite",
    "follower" => "follow",
    "connection" => "follow"
  }

  @doc "Pushes `notification` to `user_id`'s registered devices, if any."
  def dispatch(user_id, notification) when is_binary(user_id) do
    with true <- WebPush.configured?(),
         type when is_binary(type) <- @types[notification[:kind]],
         [_ | _] = subscriptions <- subscriptions_for(user_id, type) do
      Enum.each(subscriptions, &deliver(&1, type, notification))
    end

    :ok
  end

  def dispatch(_user_id, _notification), do: :ok

  defp subscriptions_for(user_id, type) do
    PushSubscription
    |> where([s], s.user_id == ^user_id)
    |> Repo.all()
    |> Enum.filter(&wants?(&1, type))
  end

  defp wants?(%PushSubscription{alerts: alerts}, type), do: Map.get(alerts, type, true) == true

  defp deliver(subscription, type, notification) do
    # No content: the payload says what kind of thing happened and which
    # notification it was, never a word of what was written. The client fetches
    # the rest over the authenticated API, where the reader is known.
    payload = %{
      notification_id: notification[:id],
      notification_type: type,
      preferred_locale: "de",
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
