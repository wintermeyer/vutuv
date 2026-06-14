defmodule Vutuv.Chat do
  @moduledoc """
  Persisted 1:1 direct messages.

  A conversation is one row per unordered user pair (sorted pair columns +
  unique index). Anyone activated can open one, but it only starts `accepted`
  when the recipient already follows the sender — otherwise it is `pending`:
  a message request the recipient may accept (explicitly or by replying) or
  decline. Decline is silent and permanent: the recipient never sees the
  conversation again, while for the sender it stays indistinguishable from an
  unanswered request and further sends are dropped without a signal.

  Real-time delivery runs over two PubSub topics: `"conversation:<id>"`
  carries the full message to open threads, and the recipient's
  `Vutuv.Activity` topic (`"user:<id>"`) gets a `{:new_message, ...}` event
  for the shell badge. Read state lives per participant (`last_read_at`);
  `notified_at` is the unread-email debounce marker.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Chat.{Conversation, Message, Participant}
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo

  @pubsub Vutuv.PubSub

  # Opening new message requests is the spam vector; replying never is.
  @new_conversation_limit 10
  @new_conversation_window :timer.hours(1)

  def new_conversation_limit, do: @new_conversation_limit

  ## Conversations

  @doc """
  Returns the conversation between the two users, creating it if needed.

  New conversations start `accepted` when `other` already follows `me`
  (following is opting in to hear from someone), `pending` otherwise.
  Only opening a *new pending* conversation counts against the rate limit.
  """
  def find_or_create_conversation(%User{id: id}, %User{id: id}), do: {:error, :self}

  def find_or_create_conversation(%User{} = me, %User{} = other) do
    cond do
      not (me.email_confirmed? && other.email_confirmed?) ->
        {:error, :not_activated}

      # A block stands between the pair: same opaque refusal as a report
      # freeze, so blocking is not distinguishable from being frozen/ignored.
      Vutuv.Social.blocked_between?(me.id, other.id) ->
        {:error, :frozen}

      true ->
        find_or_create_unblocked(me, other)
    end
  end

  defp find_or_create_unblocked(%User{} = me, %User{} = other) do
    {a_id, b_id} = pair(me.id, other.id)

    case get_by_pair(a_id, b_id) do
      # A report froze this pair (see Vutuv.Moderation): no new thread, no
      # explanation - the caller shows its generic "cannot receive
      # messages" notice.
      %Conversation{frozen_at: %NaiveDateTime{}} ->
        {:error, :frozen}

      # The decliner re-initiating: the non-initiator of a declined request
      # opening a thread re-opens it as a fresh request from them, rather than
      # dead-ending on the row that stays hidden from them (issue #779). The
      # original requester (the initiator) falls through and keeps their
      # declined-but-shown-pending row, so they never learn of the decline.
      %Conversation{status: "declined", initiator_id: initiator_id} = conversation
      when initiator_id != me.id ->
        reopen_declined(conversation, me, other)

      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        create_conversation(me, other, a_id, b_id)
    end
  end

  # Turn a declined request into a fresh request from `me` (the party who had
  # declined): the same accepted/pending rule and rate limit as a brand-new
  # request, with the original request's messages dropped so the new initiator
  # gets their one request message back and `last_message_at` is cleared. The
  # row, its id and its participants stay, so existing links keep resolving.
  defp reopen_declined(%Conversation{} = conversation, %User{} = me, %User{} = other) do
    status = if Vutuv.Social.user_follows_user?(other.id, me.id), do: "accepted", else: "pending"

    with :ok <- check_request_limit(me, status) do
      Repo.transaction(fn ->
        Repo.delete_all(from(m in Message, where: m.conversation_id == ^conversation.id))

        conversation
        |> Ecto.Changeset.change(initiator_id: me.id, status: status, last_message_at: nil)
        |> Repo.update!()
      end)
    end
  end

  # Canonical hex UUIDs compare like their bytes, so sorting the string ids
  # matches the DB's uuid ordering that the sorted_pair constraint checks.
  defp pair(id1, id2) when id1 < id2, do: {id1, id2}
  defp pair(id1, id2), do: {id2, id1}

  defp get_by_pair(a_id, b_id),
    do: Repo.get_by(Conversation, user_a_id: a_id, user_b_id: b_id)

  defp create_conversation(me, other, a_id, b_id) do
    status = if Vutuv.Social.user_follows_user?(other.id, me.id), do: "accepted", else: "pending"

    with :ok <- check_request_limit(me, status) do
      insert_conversation(me, other, a_id, b_id, status)
    end
  end

  defp check_request_limit(_me, "accepted"), do: :ok

  defp check_request_limit(me, "pending") do
    Vutuv.RateLimiter.hit(
      {:new_conversation, me.id},
      @new_conversation_limit,
      @new_conversation_window
    )
  end

  defp insert_conversation(me, other, a_id, b_id, status) do
    changeset =
      %Conversation{user_a_id: a_id, user_b_id: b_id, initiator_id: me.id, status: status}
      |> Conversation.changeset()

    result =
      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, conversation} ->
            Repo.insert!(%Participant{conversation_id: conversation.id, user_id: me.id})
            Repo.insert!(%Participant{conversation_id: conversation.id, user_id: other.id})
            conversation

          # Unique-index race: someone else created the pair first.
          {:error, _changeset} ->
            Repo.rollback(:exists)
        end
      end)

    case result do
      {:ok, conversation} -> {:ok, conversation}
      {:error, :exists} -> {:ok, get_by_pair(a_id, b_id)}
    end
  end

  @doc """
  The conversation as visible to `me`: participants only, and a declined
  conversation stays visible solely to its initiator (for whom it must remain
  indistinguishable from an unanswered request).
  """
  def get_conversation(%User{id: me_id}, conversation_id) do
    fetch_as_participant(me_id, conversation_id, fn query ->
      from(c in query,
        where: c.status != "declined" or c.initiator_id == ^me_id,
        # A moderation-frozen conversation is gone for BOTH participants
        # (admins read it via moderation_context/2).
        where: is_nil(c.frozen_at)
      )
    end)
  end

  # The participant-scoped fetch every conversation action starts from;
  # `narrow` adds the action's extra conditions. cast_or_nil: ids arrive from
  # URLs and phx-value attributes; garbage must read as "no such
  # conversation", not an Ecto.Query.CastError.
  defp fetch_as_participant(me_id, conversation_id, narrow \\ & &1) do
    case Vutuv.UUIDv7.cast_or_nil(conversation_id) do
      nil ->
        nil

      conversation_id ->
        from(c in Conversation,
          where: c.id == ^conversation_id,
          where: c.user_a_id == ^me_id or c.user_b_id == ^me_id
        )
        |> narrow.()
        |> Repo.one()
    end
  end

  @doc """
  The other user of a 1:1 conversation, from `me`'s perspective.
  """
  def other_user_id(%Conversation{} = conversation, me_id) do
    if conversation.user_a_id == me_id,
      do: conversation.user_b_id,
      else: conversation.user_a_id
  end

  def other_user(%Conversation{} = conversation, me_id),
    do: Repo.get!(User, other_user_id(conversation, me_id))

  @doc """
  The status a conversation shows to its initiator: a declined request
  reads "pending", so declining stays indistinguishable from being
  ignored. Part of the same invariant the listing queries and the silent
  `{:ok, :dropped}` sends enforce — every surface (web, API) must display
  status through this.
  """
  def display_status(%Conversation{status: "declined"}), do: "pending"
  def display_status(%Conversation{status: status}), do: status

  ## Sending

  @doc """
  Sends `body` into the conversation. Returns `{:ok, message}` on delivery and
  `{:ok, :dropped}` for declined conversations (silently, see moduledoc).
  While pending, the initiator may send exactly the one request message; the
  recipient replying accepts the conversation.
  """
  def send_message(%User{} = sender, conversation_id, body) do
    case fetch_as_participant(sender.id, conversation_id) do
      nil ->
        {:error, :not_participant}

      %Conversation{status: "declined"} ->
        {:ok, :dropped}

      # Frozen by a report: silently dropped, exactly like a decline, so the
      # freeze is not distinguishable from being ignored.
      %Conversation{frozen_at: %NaiveDateTime{}} ->
        {:ok, :dropped}

      %Conversation{status: "accepted"} = conversation ->
        deliver(conversation, sender, body, accept?: false)

      %Conversation{status: "pending"} = conversation ->
        send_pending(conversation, sender, body)
    end
  end

  defp send_pending(%Conversation{initiator_id: initiator_id} = conversation, sender, body) do
    cond do
      # The recipient replying is an implicit accept.
      sender.id != initiator_id ->
        deliver(conversation, sender, body, accept?: true)

      # The initiator gets exactly the one request message.
      has_message?(conversation.id) ->
        {:error, :pending_limit}

      true ->
        deliver(conversation, sender, body, accept?: false)
    end
  end

  defp has_message?(conversation_id),
    do: Repo.exists?(from(m in Message, where: m.conversation_id == ^conversation_id))

  @doc """
  Deletes one of `sender`'s own messages. Messages are otherwise immutable;
  the only caller is `Vutuv.Moderation.delete_reported_content/2` ("delete
  the reported message"), which also settles the moderation case.
  """
  def delete_message(%User{id: sender_id}, %Message{sender_id: sender_id} = message) do
    case Repo.delete(message) do
      {:ok, deleted} ->
        broadcast_message_deleted(message)
        {:ok, deleted}

      {:error, _} = error ->
        error
    end
  end

  def delete_message(%User{}, %Message{}), do: {:error, :not_allowed}

  defp deliver(conversation, sender, body, accept?: accept?) do
    changeset =
      %Message{conversation_id: conversation.id, sender_id: sender.id}
      |> Message.changeset(%{body: body})

    case Repo.transaction(fn -> insert_and_bump(changeset, conversation, accept?) end) do
      {:ok, message} ->
        message = %{message | sender: sender}
        broadcast_new_message(conversation, message)

        # Webhooks hear about it on the recipient's side (their grant, their
        # messages:read scope) — a thin envelope, never the message body.
        Vutuv.Webhooks.emit(other_user_id(conversation, sender.id), "message.created", %{
          "conversation_id" => conversation.id,
          "from" => sender.active_slug
        })

        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # Message insert + the conversation bump (last_message_at, plus the implicit
  # accept when the request's recipient replies) — one transaction.
  defp insert_and_bump(changeset, conversation, accept?) do
    case Repo.insert(changeset) do
      {:ok, message} ->
        set =
          [last_message_at: message.inserted_at] ++
            if(accept?, do: [status: "accepted"], else: [])

        Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id), set: set)
        message

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  ## Requests

  def accept_request(%User{} = me, conversation_id),
    do: answer_request(me, conversation_id, "accepted")

  def decline_request(%User{} = me, conversation_id),
    do: answer_request(me, conversation_id, "declined")

  # Only the recipient of a still-pending request may answer it.
  defp answer_request(%User{id: me_id}, conversation_id, status) do
    recipient_pending = fn query ->
      from(c in query, where: c.status == "pending" and c.initiator_id != ^me_id)
    end

    case fetch_as_participant(me_id, conversation_id, recipient_pending) do
      nil -> {:error, :not_recipient}
      conversation -> set_request_status(conversation, status)
    end
  end

  defp set_request_status(conversation, status) do
    with {:ok, updated} <-
           conversation |> Conversation.changeset(%{status: status}) |> Repo.update() do
      # Accepting flips the initiator's open thread from its "not accepted
      # yet" placeholder to a live composer, so nudge that thread to
      # re-read. Declines never broadcast: the initiator must stay unable to
      # tell a decline from being ignored.
      if status == "accepted", do: broadcast_conversation_update(updated.id)
      {:ok, updated}
    end
  end

  ## Listing

  @doc """
  `me`'s sidebar: accepted conversations plus their own outgoing requests
  (pending *and* declined, so a decline stays unobservable), newest activity
  first, each with the other user, a preview and the unread count.
  """
  def list_conversations(%User{id: me_id}) do
    from(c in Conversation,
      where: c.user_a_id == ^me_id or c.user_b_id == ^me_id,
      where: is_nil(c.frozen_at),
      where:
        c.status == "accepted" or
          (c.initiator_id == ^me_id and c.status in ["pending", "declined"]),
      # Conversations nobody has written into yet only show for their creator.
      where: not is_nil(c.last_message_at) or c.initiator_id == ^me_id,
      order_by: [desc_nulls_last: c.last_message_at, desc: c.id]
    )
    |> Repo.all()
    |> hydrate(me_id)
  end

  @doc """
  Message requests: pending conversations with at least one message where
  `me` is the recipient.
  """
  def list_requests(%User{id: me_id}) do
    from(c in Conversation,
      where: c.user_a_id == ^me_id or c.user_b_id == ^me_id,
      where: is_nil(c.frozen_at),
      where: c.status == "pending" and c.initiator_id != ^me_id,
      where: not is_nil(c.last_message_at),
      order_by: [desc: c.last_message_at, desc: c.id]
    )
    |> Repo.all()
    |> hydrate(me_id)
  end

  # Resolve the other user, last-message preview and unread count for a page
  # of conversations in three batched queries — no per-row queries.
  defp hydrate([], _me_id), do: []

  defp hydrate(conversations, me_id) do
    ids = Enum.map(conversations, & &1.id)
    other_ids = Enum.map(conversations, &other_user_id(&1, me_id))

    others =
      from(u in User, where: u.id in ^other_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    previews =
      from(m in Message,
        where: m.conversation_id in ^ids,
        # A frozen message must not leak into the sidebar preview of the
        # other participant; the sender still sees their own.
        where: is_nil(m.frozen_at) or m.sender_id == ^me_id,
        distinct: m.conversation_id,
        order_by: [asc: m.conversation_id, desc: m.inserted_at, desc: m.id],
        select: {m.conversation_id, {m.body, m.inserted_at}}
      )
      |> Repo.all()
      |> Map.new()

    unreads = unread_counts(ids, me_id)

    Enum.map(conversations, fn conversation ->
      {last_body, last_at} = Map.get(previews, conversation.id, {nil, nil})

      %{
        conversation: conversation,
        other: Map.fetch!(others, other_user_id(conversation, me_id)),
        last_body: last_body,
        last_at: last_at,
        unread: Map.get(unreads, conversation.id, 0)
      }
    end)
  end

  defp unread_counts(conversation_ids, me_id) do
    from(m in Message,
      join: p in Participant,
      on: p.conversation_id == m.conversation_id and p.user_id == ^me_id,
      where: m.conversation_id in ^conversation_ids,
      where: m.sender_id != ^me_id,
      # Frozen messages are invisible to the recipient, so they must not
      # count as unread either (the badge would point at nothing).
      where: is_nil(m.frozen_at),
      where: is_nil(p.last_read_at) or m.inserted_at > p.last_read_at,
      group_by: m.conversation_id,
      select: {m.conversation_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## Thread pagination

  @doc """
  One page of the thread, newest first (callers render oldest-to-newest by
  reversing). Keyset cursor `%{at:, id:}` — UUID v7 ids sort by creation time,
  so `id` is a valid tiebreaker. Non-participants get an empty page.
  """
  def messages_page(%User{} = me, conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    cursor = Keyword.get(opts, :cursor)

    case get_conversation(me, conversation_id) do
      nil ->
        %{entries: [], more?: false, next_cursor: nil}

      %Conversation{} = conversation ->
        entries =
          from(m in Message,
            where: m.conversation_id == ^conversation.id,
            # The moderation freezer: a frozen message is hidden from the
            # other participant but stays visible to its sender.
            where: is_nil(m.frozen_at) or m.sender_id == ^me.id,
            order_by: [desc: m.inserted_at, desc: m.id],
            limit: ^(limit + 1),
            preload: :sender
          )
          |> before_cursor(cursor)
          |> Repo.all()

        more? = length(entries) > limit
        entries = Enum.take(entries, limit)

        next_cursor =
          if more? do
            oldest = List.last(entries)
            %{at: oldest.inserted_at, id: oldest.id}
          end

        %{entries: entries, more?: more?, next_cursor: next_cursor}
    end
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, %{at: at, id: id}) do
    from(m in query,
      where: m.inserted_at < ^at or (m.inserted_at == ^at and m.id < ^id)
    )
  end

  ## Read state

  @doc """
  Marks the conversation read for `me`: the read marker advances to the newest
  message (not wall clock, so a message arriving during the read stays unread
  — same reasoning as `Vutuv.Activity.mark_notifications_read/1`), the
  unread-email debounce re-arms, and the shell badge is told to clear.

  Both `messages.inserted_at` and `participants.last_read_at` carry microsecond
  precision, so a message inserted in the same wall-clock second as the read
  still has a strictly greater `inserted_at` and stays unread (issue #776).
  """
  def mark_read(%User{id: me_id}, conversation_id) do
    marker =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        select: max(m.inserted_at)
      )
      |> Repo.one() || NaiveDateTime.utc_now(:microsecond)

    from(p in Participant,
      where: p.conversation_id == ^conversation_id and p.user_id == ^me_id
    )
    |> Repo.update_all(set: [last_read_at: marker, notified_at: nil])

    Activity.mark_messages_read(me_id)
    :ok
  end

  @doc """
  How many conversations hold unread messages for the user — the shell badge.
  Pending requests count for their recipient (that is how requests get
  noticed); declined conversations count for nobody.
  """
  def unread_conversations_count(nil), do: 0

  def unread_conversations_count(%User{id: me_id}), do: unread_conversations_count(me_id)

  def unread_conversations_count(me_id) do
    from(c in Conversation,
      join: p in Participant,
      on: p.conversation_id == c.id and p.user_id == ^me_id,
      join: m in Message,
      on: m.conversation_id == c.id,
      where: is_nil(c.frozen_at),
      where:
        c.status == "accepted" or
          (c.status == "pending" and c.initiator_id != ^me_id),
      where: m.sender_id != ^me_id,
      # Frozen messages are invisible to the recipient (see hydrate/2), so
      # they must not light the shell badge either.
      where: is_nil(m.frozen_at),
      where: is_nil(p.last_read_at) or m.inserted_at > p.last_read_at,
      select: count(c.id, :distinct)
    )
    |> Repo.one()
  end

  ## Unread email notifications

  # How long a message may sit unread before the email goes out. Long enough
  # that an active back-and-forth never emails mid-exchange.
  @unread_email_delay_minutes 15

  @doc """
  Emails every participant whose conversation holds messages left unread past
  the debounce delay — at most one email per conversation per unread burst
  (`notified_at` is set here and nulled by `mark_read/2`). Only accepted
  conversations qualify: a stranger's pending request must never be able to
  push email to anyone. Called by `Vutuv.Chat.UnreadNotifier`; returns the
  number of emails sent.
  """
  def send_unread_notifications do
    cutoff =
      NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@unread_email_delay_minutes * 60)

    query =
      from(p in Participant,
        join: c in Conversation,
        on: c.id == p.conversation_id,
        where: c.status == "accepted",
        where: is_nil(c.frozen_at),
        where: is_nil(p.notified_at),
        where:
          fragment(
            """
            EXISTS (SELECT 1 FROM messages m
                    WHERE m.conversation_id = ?
                      AND m.sender_id <> ?
                      AND m.frozen_at IS NULL
                      AND (? IS NULL OR m.inserted_at > ?)
                      AND m.inserted_at < ?)
            """,
            p.conversation_id,
            p.user_id,
            p.last_read_at,
            p.last_read_at,
            type(^cutoff, :naive_datetime)
          ),
        select: {p, c}
      )

    rows = Repo.all(query)

    # Batch-load every user this path touches (recipients and their
    # counterparts) in one query instead of two Repo.get! per row, the way
    # hydrate/2 does. The recipient's first email stays a per-row lookup
    # because first_email_value/1 has no deterministic batch equivalent.
    user_ids =
      Enum.flat_map(rows, fn {participant, conversation} ->
        [participant.user_id, other_user_id(conversation, participant.user_id)]
      end)

    users =
      from(u in User, where: u.id in ^user_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.count(rows, fn {participant, conversation} ->
      recipient = Map.fetch!(users, participant.user_id)
      other = Map.fetch!(users, other_user_id(conversation, participant.user_id))
      notify_participant(participant, conversation, recipient, other)
    end)
  end

  defp notify_participant(participant, conversation, recipient, other) do
    # An opted-out recipient (notification_emails? false) is skipped without
    # setting notified_at, so switching the emails back on makes a still-
    # unread burst eligible again on the next tick.
    email = recipient.notification_emails? && Vutuv.Accounts.first_email_value(recipient)

    if email do
      email
      |> Emailer.unread_messages_email(recipient, other, conversation.id)
      |> Emailer.deliver()

      from(p in Participant, where: p.id == ^participant.id)
      |> Repo.update_all(set: [notified_at: NaiveDateTime.utc_now(:second)])

      true
    else
      false
    end
  end

  ## Conversation lifecycle predicates (the display twins of send_message/3)

  @doc """
  Whether `user_id` may write into the conversation right now: declined
  conversations never accept input (and must look pending to their
  initiator), and a pending initiator is done after the one request message.
  The recipient always has a composer — their reply accepts the request.
  """
  def can_send?(%Conversation{status: "accepted"}, _user_id), do: true
  def can_send?(%Conversation{status: "declined"}, _user_id), do: false

  def can_send?(%Conversation{status: "pending"} = conversation, user_id),
    do: conversation.initiator_id != user_id or is_nil(conversation.last_message_at)

  @doc """
  Whether the conversation is a message request waiting on `user_id`.
  """
  def request_recipient?(%Conversation{} = conversation, user_id),
    do: conversation.status == "pending" and conversation.initiator_id != user_id

  ## PubSub

  def subscribe(conversation_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic(conversation_id))

  @doc """
  Tells the other open sessions of the conversation that `name` is typing.
  `broadcast_from`: the typist's own session must not see the indicator.
  """
  def broadcast_typing(conversation_id, name),
    do: Phoenix.PubSub.broadcast_from(@pubsub, self(), topic(conversation_id), {:typing, name})

  @doc """
  For admins reviewing a reported message: the message itself plus up to `n`
  messages before it in the same conversation, oldest first. Only the
  moderation review path may call this — it deliberately bypasses the
  participant check.
  """
  def moderation_context(%Message{} = message, n \\ 5) do
    from(m in Message,
      where: m.conversation_id == ^message.conversation_id,
      where:
        m.inserted_at < ^message.inserted_at or
          (m.inserted_at == ^message.inserted_at and m.id <= ^message.id),
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^(n + 1),
      preload: :sender
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Whether an unfrozen conversation exists between the two - i.e. whether a
  report would freeze something. Backs the report form's "this will separate
  you" warning (`Vutuv.Moderation`).
  """
  def active_conversation_between?(user_id, other_id) do
    {a_id, b_id} = pair(user_id, other_id)
    match?(%Conversation{frozen_at: nil}, get_by_pair(a_id, b_id))
  end

  @doc """
  Freezes the 1:1 conversation between the two users, if one exists and is
  not already frozen: it disappears for both sides and accepts no new
  messages. Returns the conversation this call froze, or nil (no
  conversation, or already frozen by an earlier report - the earlier case
  then owns the eventual unfreeze). Called by `Vutuv.Moderation` when a
  report severs the relationship.
  """
  def freeze_conversation_between(user_id, other_id) do
    {a_id, b_id} = pair(user_id, other_id)

    case get_by_pair(a_id, b_id) do
      %Conversation{frozen_at: nil} = conversation ->
        conversation
        |> Ecto.Changeset.change(frozen_at: NaiveDateTime.utc_now(:second))
        |> Repo.update!()

      _ ->
        nil
    end
  end

  @doc """
  The id of the frozen 1:1 conversation between the two, or nil. Used when a
  block must adopt freeze-ownership of a conversation a rejected report leaves
  frozen, without relying on which moderation severance happened to record it.
  """
  def frozen_conversation_id_between(user_id, other_id) do
    {a_id, b_id} = pair(user_id, other_id)

    Repo.one(
      from(c in Conversation,
        where: c.user_a_id == ^a_id and c.user_b_id == ^b_id and not is_nil(c.frozen_at),
        select: c.id
      )
    )
  end

  @doc "Thaws a report-frozen conversation (a rejected report restores it)."
  def unfreeze_conversation(%Conversation{} = conversation) do
    conversation
    |> Ecto.Changeset.change(frozen_at: nil)
    |> Repo.update!()
  end

  @doc """
  A message just entered the moderation freezer: open threads drop it for the
  recipient and dim it for the sender (see `VutuvWeb.MessageLive.Index`).
  Called by `Vutuv.Moderation` when it freezes a message.
  """
  def broadcast_message_frozen(%Message{} = message) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(message.conversation_id),
      {:message_frozen, %{message_id: message.id, sender_id: message.sender_id}}
    )
  end

  @doc """
  A message was deleted (moderation removing reported content): open threads
  drop the bubble for both participants and refresh their sidebar preview, so a
  deleted message can't be read until the next reload.
  """
  def broadcast_message_deleted(%Message{} = message) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(message.conversation_id),
      {:message_deleted, %{message_id: message.id, conversation_id: message.conversation_id}}
    )
  end

  defp topic(conversation_id), do: "conversation:#{conversation_id}"

  # The open thread gets the full message; the recipient's activity topic gets
  # the badge event (the sender's badge must not light for their own message).
  defp broadcast_new_message(conversation, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic(conversation.id), {:new_message, message})

    recipient_id = other_user_id(conversation, message.sender_id)
    Activity.broadcast(recipient_id, {:new_message, %{conversation_id: conversation.id}})
  end

  # A request was accepted: nudge the conversation's open threads (the
  # initiator's especially) to re-read their now-accepted state. Plain
  # broadcast, so the accepting session simply re-reads harmlessly too.
  defp broadcast_conversation_update(conversation_id),
    do:
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(conversation_id),
        {:conversation_updated, conversation_id}
      )
end
