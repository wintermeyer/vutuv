defmodule VutuvWeb.Presence do
  @moduledoc """
  Tracks who is online for the real-time green "online" dot on avatars (and the
  messaging shell). Backed by the already-running `Vutuv.PubSub`.

  Site-wide presence lives on a single topic (`online_topic/0`). `ShellLive`,
  embedded on every page, tracks the current member there the moment any page's
  socket connects and untracks them automatically when their last tab closes,
  they lose connection, or they log out. The helpers below are the one place
  that names the topic, so every consumer (the shell, the messages page) reads
  the same set.
  """
  use Phoenix.Presence,
    otp_app: :vutuv,
    pubsub_server: Vutuv.PubSub

  @online_topic "users:online"

  @doc "The single site-wide topic carrying who is online."
  def online_topic, do: @online_topic

  @doc """
  Marks `user_id` online on the site-wide topic (no-op for a nil id). Tracking
  is by process: when the tracking LiveView dies, Presence emits the leave on
  its own. Many tabs/processes can track the same member; `online_ids/0` lists
  one entry per id regardless.
  """
  def track_user(pid, user_id) when is_binary(user_id) or is_integer(user_id),
    do: track(pid, @online_topic, to_string(user_id), %{})

  def track_user(_pid, _user_id), do: :ok

  @doc "Removes `user_id`'s presence under `pid` (used when a member opts out live)."
  def untrack_user(pid, user_id) when is_binary(user_id) or is_integer(user_id),
    do: untrack(pid, @online_topic, to_string(user_id))

  def untrack_user(_pid, _user_id), do: :ok

  @doc "Subscribes the caller to site-wide presence diffs (joins/leaves)."
  def subscribe_online, do: Phoenix.PubSub.subscribe(Vutuv.PubSub, @online_topic)

  @doc "The set of currently-online user ids (as strings)."
  def online_ids, do: @online_topic |> list() |> Map.keys() |> MapSet.new()

  @doc "Whether `user_id` is in a given online-id set."
  def online?(online_ids, user_id), do: MapSet.member?(online_ids, to_string(user_id))
end
