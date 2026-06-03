defmodule Vutuv.Activity do
  @moduledoc """
  In-app real-time activity bus.

  Thin wrapper over `Phoenix.PubSub` (`Vutuv.PubSub`) used to push live updates
  to a user's open sessions: new follower / endorsement / connection bump the
  notification badge, new messages bump the message badge. This is **not** email
  — outbound mail still goes through `Vutuv.Notifications.Emailer`.

  Topic per user is `"user:<id>"`. The shell (`VutuvWeb.ShellLive`) and the
  notification / message LiveViews subscribe to it.
  """
  @pubsub Vutuv.PubSub

  def topic(user_id), do: "user:#{user_id}"

  def subscribe(nil), do: :ok
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(user_id))

  @doc "Broadcast a raw event to a user's topic (no-op for a nil recipient)."
  def broadcast(nil, _event), do: :ok
  def broadcast(user_id, event), do: Phoenix.PubSub.broadcast(@pubsub, topic(user_id), event)

  @doc "Tell a user's shell their notifications were just read (clears the badge)."
  def mark_notifications_read(user_id), do: broadcast(user_id, :notifications_read)

  @doc "Tell a user's shell their messages were just read (clears the badge)."
  def mark_messages_read(user_id), do: broadcast(user_id, :messages_read)

  @doc "Push a new in-app notification to `user_id`."
  def notify(nil, _notification), do: :ok
  def notify(user_id, %{} = notification),
    do: broadcast(user_id, {:new_notification, notification})

  @doc """
  Convenience: a "started following you" notification for the followee. Carries
  the actor's name, route param, and avatar so the notifications page can link
  to the follower's profile and show their picture.
  """
  def notify_new_follower(followee_id, follower) do
    notify(followee_id, %{
      kind: "follower",
      text: "started following you.",
      actor_name: display_name(follower),
      actor_param: actor_param(follower),
      actor_avatar: actor_avatar(follower),
      at: DateTime.utc_now()
    })
  end

  defp actor_param(%Vutuv.Accounts.User{} = user), do: Phoenix.Param.to_param(user)
  defp actor_param(_), do: nil

  defp actor_avatar(%Vutuv.Accounts.User{} = user), do: Vutuv.Avatar.display_url(user, :thumb)
  defp actor_avatar(_), do: nil

  defp display_name(%{first_name: first, last_name: last}) do
    [first, last]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> "Someone"
      name -> name
    end
  end

  defp display_name(_), do: "Someone"
end
