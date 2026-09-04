defmodule Vutuv.WebPush.Dispatcher do
  @moduledoc """
  Turns a member's new notification into a Web Push to their own installed app
  (issue #1729) — the sibling of `Vutuv.MastodonApi.PushDispatcher`, which does
  the same for third-party phone clients.

  Hooked into `Vutuv.Activity.notify/2`, the one place a notification is
  announced, so a push cannot drift out of step with what the website shows.
  Sending is **fire and forget in a task**: a push service is somebody else's
  machine on the other side of the internet, and the member's own action —
  liking, following, replying — must not wait on it or fail with it.

  Two switches have to be on. The account's `browser_notifications?` is the
  master one (nobody who never asked for notifications is ever pushed to), and
  the per-device answer is the existence of a `Vutuv.WebPush.Subscription` row:
  a subscription belongs to a browser, so "also when vutuv is closed" is a
  question each phone answers for itself.

  The payload carries **no content** — the kind of thing that happened, where it
  leads, and the member's own unread total for the icon. Never a word of what
  was written: the service worker draws a generic line per kind in the member's
  own language, because what a push turns into here is text on a lock screen,
  and the bell is one tap away.
  """

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Chat
  alias Vutuv.Languages
  alias Vutuv.Repo
  alias Vutuv.WebPush
  alias Vutuv.WebPush.Subscription
  alias VutuvWeb.NotificationLine

  @doc "Pushes `notification` to `user_id`'s registered browsers, if any."
  # **Nothing here touches the database on the caller's process.** `notify/2` is
  # the notification chokepoint, so this runs inside whatever action produced
  # the notification — often inside its transaction — and a member liking a post
  # should not wait on reads that only a push service will ever care about. The
  # one decision made here is the operator's switch, because it costs no query
  # and skips the task entirely.
  def dispatch(user_id, notification) when is_binary(user_id) do
    if WebPush.enabled?() do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
        fan_out(user_id, notification)
      end)
    end

    :ok
  end

  def dispatch(_user_id, _notification), do: :ok

  @doc """
  Pushes a new direct message to `recipient_id`'s registered browsers.

  Its own entry point because a message is not a `notify/2` notification: it
  moves the shell's second badge over its own broadcast (`Vutuv.Chat`), so
  hanging it off the notification chokepoint would have missed it — and a
  waiting answer is the thing a member most wants their phone to tell them
  about.

  **The recipient is not always an id.** `Vutuv.Chat.recipient/2` answers three
  shapes: a member's id, `nil`, and — for a conversation whose far side is a
  page — an `%Vutuv.Organizations.Organization{}` struct. Only the first is a
  member with devices of their own; a page's team hears about it on the page's
  own topic while they are speaking as it, which is a shell badge and not a
  phone. `dispatch/2`'s `is_binary` guard is what turns the other two into a
  no-op, so both are covered by one rule rather than by remembering the struct.
  """
  def dispatch_message(recipient_id), do: dispatch(recipient_id, %{kind: "message"})

  # The body of that task: one query and the sends.
  #
  # One query, not two: the join carries the member's locale and handle along,
  # the way `Vutuv.MastodonApi.PushDispatcher` already does it, and the
  # `browser_notifications?` gate rides in the same `where` — so a member who
  # never switched notifications on costs one indexed query that returns
  # nothing, rather than a row-returning read followed by a second one.
  #
  # `notify/2` is called in fan-out loops (every participant of a thread, every
  # rewritten author), so this runs N times for one reply and the difference is
  # not academic.
  defp fan_out(user_id, notification) do
    case devices(user_id) do
      [] ->
        :ok

      devices ->
        # Read once for the member, not once per device, and only where a device
        # is really waiting — which is what keeps `badge_count/1`'s reads off
        # every notification of every member who never installed the app.
        unread = badge_count(user_id)

        Enum.each(devices, fn {subscription, locale, param} ->
          deliver(subscription, notification, locale, param, unread)
        end)
    end
  end

  @doc """
  The number the installed app's icon carries, for a member whose app is shut.

  The same two counts `VutuvWeb.ShellLive.push_badge/1` sends an open page (the
  feed's own badge is deliberately not among them), read from the database here
  because the page that holds them is precisely what a push exists in the
  absence of.

  **Never zero.** `Vutuv.Activity.notify/2` often runs inside the transaction
  that produced the notification while this reads from another process, so the
  row that caused this very push may not be visible yet — and a zero would take
  the badge *off* at the moment something arrived, which is the one answer that
  is certainly wrong. Being one short for a few seconds is not: the open app
  recomputes the whole number the instant the member taps the icon.
  """
  def badge_count(user_id) do
    max(Chat.unread_conversations_count(user_id) + Activity.unread_notification_count(user_id), 1)
  end

  # The member's own language, not a hardcoded "de", and their handle for the
  # destination the tap lands on. `Vutuv.Languages.user_locale/1` owns the
  # fallback, shared with the phone-client dispatcher.
  defp devices(user_id) do
    from(s in Subscription,
      join: u in User,
      on: u.id == s.user_id,
      where: s.user_id == ^user_id and u.browser_notifications? == true,
      select: {s, u.locale, u.username}
    )
    |> Repo.all()
    |> Enum.map(fn {subscription, locale, param} ->
      {subscription, Languages.user_locale(locale), param}
    end)
  end

  defp deliver(subscription, notification, locale, param, unread) do
    payload = %{
      kind: notification[:kind],
      locale: locale,
      # What goes on the Home Screen icon (issue #1732). It rides in the payload
      # rather than being counted in the worker, because a service worker has no
      # session and no database — and the Badging API can only be written, never
      # read, so it cannot count for itself either.
      unread: unread,
      # Where the row under the bell would take them — the post, the case, the
      # profile. A push is raised precisely when the member is NOT looking at
      # vutuv, so the notifications list is the one place that makes them hunt
      # for what they were just told about.
      url: target(notification, param)
    }

    # Sequentially, unlike the Mastodon fan-out's task per subscription: a
    # member has a phone and a laptop, not a fleet, and the whole of this
    # already runs off the caller's process. `push/2` owns what happens to a
    # subscription the push service reports as dead.
    WebPush.push(subscription, payload)
  end

  # A message is not under the bell, so its own page is where the tap lands —
  # the one kind `VutuvWeb.NotificationLine` cannot answer for, because a
  # message never becomes a notification row.
  defp target(%{kind: "message"}, _param), do: "/messages"
  defp target(notification, param), do: NotificationLine.notification_url(notification, param)
end
