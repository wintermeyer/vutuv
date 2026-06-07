defmodule Vutuv.Chat.Participant do
  @moduledoc false

  use VutuvWeb, :model

  schema "conversation_participants" do
    belongs_to(:conversation, Vutuv.Chat.Conversation)
    belongs_to(:user, Vutuv.Accounts.User)

    # null = never opened the conversation.
    field(:last_read_at, :naive_datetime)
    # When the unread-notification email for the current unread burst went
    # out; nulled on read so the next burst may email again.
    field(:notified_at, :naive_datetime)

    timestamps()
  end
end
