defmodule Vutuv.Repo.Migrations.BackfillFediverseConversations do
  @moduledoc """
  Gives every private message that already arrived or left its conversation.

  Two stores held them before this: a private answer written on another
  network under a member's post is a `fediverse_notes` row with
  `audience = 'direct'`, and an answer the member sent back is a
  `fediverse_private_messages` row. Both keep rendering under the post, exactly
  where their authors left them; this only adds the second view, so a member
  opening `/messages` finds the correspondence that already existed rather
  than an empty list beside a post that clearly has one.

  Three decisions the rows themselves cannot make:

    * **Whose conversation.** A note's member is the owner of the post it hangs
      off; a sent message names its member directly.
    * **Who started it, and whether it is a request.** The earliest message
      decides `initiator_id` (NULL when the other side wrote first, which is
      what marks the member as the recipient), and a conversation the member
      ever wrote into counts as accepted — they answered, which is what
      accepting means everywhere else here.
    * **Which account row.** Most senders are stored already; the ones that are
      not are minted from what the note recorded (handle, inbox), because a
      conversation hangs off an account row and there is nobody to ask.

  Written in SQL with ids minted here rather than through the schemas: a
  migration that names today's modules breaks the day one of them changes, and
  `gen_random_uuid()` would mint v4 where this codebase is v7 everywhere.
  """
  use Ecto.Migration

  alias Vutuv.UUIDv7

  def up, do: run(repo())

  @doc """
  The backfill itself, against `repo`.

  Split out of `up/0` because `repo()` only answers inside a migration runner,
  and a data migration whose row-touching branches nothing ever executes is how
  a backfill ships broken: a fresh test database holds no rows for it to find,
  so `test/vutuv/fediverse_conversation_backfill_test.exs` drives this with
  rows shaped like production's.
  """
  def run(repo) do
    accounts = existing_accounts(repo)

    events = incoming_events(repo) ++ outgoing_events(repo)

    {accounts, minted} = mint_missing_accounts(repo, events, accounts)

    written =
      events
      |> Enum.group_by(fn event -> {event.user_id, Map.fetch!(accounts, event.actor_uri)} end)
      |> Enum.map(fn {{user_id, account_id}, group} ->
        insert_conversation(repo, user_id, account_id, group)
      end)

    IO.puts(
      "backfill_fediverse_conversations: #{length(written)} conversation(s), " <>
        "#{Enum.sum(written)} message(s), #{minted} account row(s) minted"
    )
  end

  def down do
    # The conversations this created are indistinguishable from ones made
    # since, so nothing is removed: the rows are the member's own mail, and
    # the structural migration beside this one is what a rollback undoes.
    :ok
  end

  # A private answer that arrived under one of the member's own posts.
  defp incoming_events(repo) do
    """
    SELECT n.id, n.object_uri, n.actor_uri, n.content_text, n.received_at,
           n.handle, n.display_name, n.inbox_uri, p.user_id
      FROM fediverse_notes n
      JOIN posts p ON p.id = n.post_id
     WHERE n.audience = 'direct' AND p.user_id IS NOT NULL
     ORDER BY n.received_at
    """
    |> query(repo)
    |> Enum.map(fn [id, object_uri, actor_uri, body, at, handle, name, inbox, user_id] ->
      %{
        direction: :in,
        note_id: id,
        private_message_id: nil,
        remote_object_uri: object_uri,
        actor_uri: actor_uri,
        body: body,
        at: naive(at),
        handle: handle,
        name: name,
        inbox: inbox,
        user_id: user_id
      }
    end)
  end

  # An answer the member sent back.
  defp outgoing_events(repo) do
    """
    SELECT m.id, m.recipient_actor_uri, m.body, m.inserted_at, m.user_id
      FROM fediverse_private_messages m
     ORDER BY m.inserted_at
    """
    |> query(repo)
    |> Enum.map(fn [id, actor_uri, body, at, user_id] ->
      %{
        direction: :out,
        note_id: nil,
        private_message_id: id,
        remote_object_uri: nil,
        actor_uri: actor_uri,
        body: body,
        at: naive(at),
        handle: nil,
        name: nil,
        inbox: nil,
        user_id: user_id
      }
    end)
  end

  defp existing_accounts(repo) do
    "SELECT actor_uri, id FROM fediverse_remote_accounts"
    |> query(repo)
    |> Map.new(fn [actor_uri, id] -> {actor_uri, uuid(id)} end)
  end

  # `DO UPDATE` rather than `DO NOTHING`, for the id: a conflicting row has to
  # come back too, or every mint needs a second SELECT to find out which id
  # survived.
  defp mint_missing_accounts(repo, events, accounts) do
    events
    |> Enum.reject(&Map.has_key?(accounts, &1.actor_uri))
    |> Enum.uniq_by(& &1.actor_uri)
    |> Enum.reduce({accounts, 0}, fn event, {acc, minted} ->
      [[id]] =
        query(
          """
          INSERT INTO fediverse_remote_accounts
            (id, actor_uri, host, handle, name, inbox_uri, inserted_at, updated_at)
          VALUES ($1::text::uuid, $2, $3, $4, $5, $6, now(), now())
          ON CONFLICT (actor_uri) DO UPDATE SET updated_at = EXCLUDED.updated_at
          RETURNING id
          """,
          repo,
          [
            UUIDv7.generate(),
            event.actor_uri,
            host(event.actor_uri),
            event.handle,
            event.name,
            inbox(event)
          ]
        )

      {Map.put(acc, event.actor_uri, uuid(id)), minted + 1}
    end)
  end

  defp insert_conversation(repo, user_id, account_id, events) do
    events = Enum.sort_by(events, & &1.at, NaiveDateTime)
    first = List.first(events)
    answered? = Enum.any?(events, &(&1.direction == :out))
    last_at = events |> List.last() |> Map.fetch!(:at)

    [[conversation_id]] =
      query(
        """
        INSERT INTO conversations
          (id, user_a_id, remote_account_id, initiator_id, status, last_message_at,
           inserted_at, updated_at)
        VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5,
                $6::timestamp, now(), now())
        ON CONFLICT (user_a_id, remote_account_id)
          DO UPDATE SET last_message_at = EXCLUDED.last_message_at
        RETURNING id
        """,
        repo,
        [
          UUIDv7.generate(),
          uuid(user_id),
          account_id,
          if(first.direction == :out, do: uuid(user_id)),
          if(answered?, do: "accepted", else: "pending"),
          last_at
        ]
      )

    conversation_id = uuid(conversation_id)

    query(
      """
      INSERT INTO conversation_participants
        (id, conversation_id, user_id, inserted_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, now(), now())
      ON CONFLICT (conversation_id, user_id) DO NOTHING
      """,
      repo,
      [UUIDv7.generate(), conversation_id, uuid(user_id)]
    )

    Enum.count(events, &insert_message(repo, conversation_id, account_id, uuid(user_id), &1))
  end

  defp insert_message(repo, conversation_id, account_id, user_id, event) do
    {count, _} =
      execute_with(
        repo,
        """
        INSERT INTO messages
          (id, conversation_id, body, sender_id, sender_remote_account_id,
           note_id, private_message_id, remote_object_uri, inserted_at, updated_at)
        VALUES ($1::text::uuid, $2::text::uuid, $3, $4::text::uuid, $5::text::uuid,
                $6::text::uuid, $7::text::uuid, $8, $9::timestamp, $9::timestamp)
        ON CONFLICT DO NOTHING
        """,
        [
          UUIDv7.generate(),
          conversation_id,
          event.body,
          if(event.direction == :out, do: user_id),
          if(event.direction == :in, do: account_id),
          event.note_id && uuid(event.note_id),
          event.private_message_id && uuid(event.private_message_id),
          event.remote_object_uri,
          event.at
        ]
      )

    count > 0
  end

  defp inbox(%{inbox: inbox}) when is_binary(inbox) and inbox != "", do: inbox

  # `fediverse_remote_accounts.inbox_uri` is NOT NULL, and a note stored before
  # issue #1070 carries none. The conventional path is the honest guess, and a
  # send through it is gated by `own_inbox/1` anyway (same host), so a wrong
  # one refuses rather than delivering somewhere else.
  defp inbox(%{actor_uri: actor_uri}), do: actor_uri <> "/inbox"

  defp host(actor_uri), do: URI.parse(actor_uri).host

  defp query(sql, repo, params \\ []) do
    %{rows: rows} = repo.query!(sql, params)
    rows
  end

  defp execute_with(repo, sql, params) do
    %{num_rows: count} = result = repo.query!(sql, params)
    {count, result}
  end

  # Postgrex hands a `uuid` column back as 16 raw bytes; every parameter here
  # is cast from text, so ids travel as their readable form throughout.
  defp uuid(value) when is_binary(value) and byte_size(value) == 16,
    do: Ecto.UUID.load!(value)

  defp uuid(value), do: value

  defp naive(%NaiveDateTime{} = at), do: at
  defp naive(%DateTime{} = at), do: DateTime.to_naive(at)
end
