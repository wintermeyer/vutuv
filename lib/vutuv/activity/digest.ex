defmodule Vutuv.Activity.Digest do
  @moduledoc """
  The one way a notification reaches a member's inbox.

  Every kind follows the same three steps, and nothing has to be arranged per
  kind for it to work:

    1. the notification appears in the app, live, the moment it happens;
    2. if it is still unread `delay_minutes/0` later **and** the member has not
       used vutuv in that time, they are behind on it;
    3. one mail goes out listing everything they are behind on, and the
       high-water mark moves past it.

  Adding a kind means adding it to the `Vutuv.Activity` registry with an
  `email_pref`, and it is carried by this without another line of code. That is
  the point: the old arrangement mailed some kinds the instant they happened,
  never mailed others, and had a third mechanism again for direct messages —
  three answers to one question, each written at the call site.

  ## Why a high-water mark

  The feed is **derived** from its source tables, so there is no notification
  row to flag as sent. `users.notifications_notified_at` carries how far the
  mail has got, the way `conversation_participants.notified_at` does for direct
  messages. A member's cutoff is the later of that and their read marker, so
  reading your notifications is itself enough to stop mail about them.

  ## Reliability

  The schedule is state in the database, not in a process: `Vutuv.Activity.DigestNotifier`
  is only a timer, and a restart mid-sweep loses nothing. Per member the order
  is deliver-then-stamp, so a crash in between repeats a digest rather than
  swallowing it — for something whose whole job is not to drop news, a repeat
  is the safe failure. One member's failure never touches another's: each is
  its own try/rescue.

  Direct messages keep their own sweeper (`Vutuv.Chat.UnreadNotifier`). They
  are not notifications — they are a conversation with its own read state,
  its own per-member delay and its own "every message or just the first"
  choice — so folding them in here would mean teaching this about all three.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo
  alias Vutuv.Sessions

  # How long a notification may sit unread before it is mailed. Long enough
  # that somebody who steps away from the keyboard and comes back finds it
  # already read and is never mailed at all; short enough that news which
  # matters the same day still travels the same day.
  @default_delay_minutes 30

  # The most lines one mail carries. Past it the digest says how many more
  # there are: a mail listing two hundred events is not a summary of anything.
  @max_lines 20

  # How many members one sweep mails. A cap rather than an unbounded run, so a
  # backlog drains over several sweeps instead of holding one long transaction
  # and a burst of SMTP.
  @batch 200

  @doc "How long a notification may sit unread before it is mailed."
  def delay_minutes,
    do: Application.get_env(:vutuv, :notification_digest_delay_minutes, @default_delay_minutes)

  @doc """
  Mails every member who is behind on their notifications. Returns how many
  mails went out. Called by `Vutuv.Activity.DigestNotifier`.
  """
  def send_pending do
    delay = delay_minutes()
    cutoff = DateTime.add(DateTime.utc_now(:second), -delay * 60, :second)

    # Read once per sweep, not once per member: it walks the whole registry.
    prefs = Activity.kind_email_prefs()

    candidates()
    |> Enum.map(&deliver(&1, cutoff, delay, prefs))
    |> Enum.count(& &1)
  end

  # Who is even worth looking at: a confirmed address, notification mail on at
  # all, and something in the feed since the marker. The per-kind preferences
  # and the "have they been here" test need the events themselves, so they run
  # per candidate rather than in SQL — this query is only there to keep that
  # work off the whole member table.
  defp candidates do
    Repo.all(
      from(u in User,
        where: u.email_confirmed? == true and u.notification_emails? == true,
        order_by: [asc: u.id],
        limit: @batch,
        select: u
      )
    )
  end

  defp deliver(%User{} = user, cutoff, delay, prefs) do
    since = cutoff_for(user)

    with false <- Sessions.active_since?(user.id, delay * 60),
         [_ | _] = events <- mailable_events(user, since, cutoff, prefs) do
      send_digest(user, events)
    else
      _nothing_to_say -> false
    end
  rescue
    error ->
      Logger.error("notification digest for #{user.id} failed: #{Exception.message(error)}")
      false
  end

  # Everything the member has not seen, has not been mailed, is old enough to
  # have been missed, and wants by mail.
  defp mailable_events(user, since, cutoff, prefs) do
    user.id
    |> Activity.events_since(since, @max_lines + 1)
    |> Enum.filter(&mailable?(&1, user, prefs, cutoff))
  end

  defp mailable?(event, user, prefs, cutoff) do
    case Map.get(prefs, event[:kind]) do
      nil -> false
      field -> Map.get(user, field) == true and older_than?(event[:at], cutoff)
    end
  end

  # Only events that have had their chance to be seen in the app. A brand-new
  # one waits for the next sweep, which is what makes this a digest rather than
  # an instant mail with extra steps.
  defp older_than?(nil, _cutoff), do: false

  defp older_than?(%DateTime{} = at, cutoff), do: DateTime.compare(at, cutoff) == :lt

  defp older_than?(%NaiveDateTime{} = at, cutoff),
    do: at |> DateTime.from_naive!("Etc/UTC") |> older_than?(cutoff)

  defp send_digest(user, events) do
    shown = Enum.take(events, @max_lines)
    more = length(events) - length(shown)

    case Vutuv.Accounts.first_email_value(user) do
      address when is_binary(address) ->
        address
        |> Emailer.notification_digest_email(user, shown, more)
        |> Emailer.deliver()

        stamp(user, shown)
        true

      _no_address ->
        false
    end
  end

  # Past the newest event in this mail, never simply "now": an event that
  # arrived while the mail was being built has not been mailed and must not be
  # skipped.
  defp stamp(user, events) do
    newest = events |> Enum.map(&as_utc(&1[:at])) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime)

    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      set: [notifications_notified_at: newest]
    )
  end

  # The later of "already mailed" and "already read": either is reason enough
  # not to mail an event again.
  defp cutoff_for(%User{} = user) do
    [as_utc(user.notifications_notified_at), as_utc(user.notifications_read_at)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      stamps -> Enum.max(stamps, DateTime)
    end
  end

  defp as_utc(nil), do: nil
  defp as_utc(%DateTime{} = at), do: at
  defp as_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
