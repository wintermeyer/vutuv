defmodule Vutuv.Chat.Participant do
  @moduledoc false

  use VutuvWeb, :model

  schema "conversation_participants" do
    belongs_to(:conversation, Vutuv.Chat.Conversation)
    # The party this row's read state belongs to: a member, or a page (issue
    # #1336). For a page it is ONE row for the whole team, not one per
    # publisher — read means somebody read it, never that everybody did, the
    # same model as `organizations.activity_read_at`. A row per publisher would
    # also have to be minted and retired as roles change.
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)

    # null = never opened the conversation. Microsecond precision so the read
    # marker (`max(messages.inserted_at)`) keeps its sub-second resolution and
    # a same-second message stays unread — issue #776 (4b).
    field(:last_read_at, :naive_datetime_usec)
    # When the unread-notification email for the current unread burst went
    # out; nulled on read so the next burst may email again.
    field(:notified_at, :naive_datetime)

    timestamps()
  end
end
