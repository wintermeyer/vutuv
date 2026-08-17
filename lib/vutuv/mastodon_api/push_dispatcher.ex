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
      locale = preferred_locale(user_id)
      Enum.each(subscriptions, &deliver(&1, type, notification, locale))
    end

    :ok
  end

  def dispatch(_user_id, _notification), do: :ok

  # Joined to the token rather than selected on `user_id` alone: revoking a
  # credential marks it `revoked_at` instead of deleting it, so the
  # subscription's cascade never fires and a device the member signed out of
  # would keep being pushed to. `Vutuv.ApiAuth` deletes the row as well; this is
  # the check that cannot be forgotten by a revocation path added later.
  defp subscriptions_for(user_id, type) do
    from(s in PushSubscription,
      join: t in Token,
      on: t.id == s.api_token_id,
      where: s.user_id == ^user_id and is_nil(t.revoked_at)
    )
    |> Repo.all()
    |> Enum.filter(&wants?(&1, type))
  end

  defp wants?(%PushSubscription{alerts: alerts}, type), do: Map.get(alerts, type, true) == true

  # The member's own language, not a hardcoded "de": vutuv is installable by
  # third parties, and a client uses this to pick which of its own strings to
  # show beside the notification. A member who never chose falls back to the
  # same "en" `VutuvWeb.Plugs.Locale` falls back to, so the push and the website
  # cannot disagree about what language they think this person reads.
  @fallback_locale "en"

  defp preferred_locale(user_id) do
    case Repo.get(User, user_id) do
      %User{locale: locale} when is_binary(locale) and locale != "" -> locale
      _no_choice -> @fallback_locale
    end
  end

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
