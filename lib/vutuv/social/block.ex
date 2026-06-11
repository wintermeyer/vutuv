defmodule Vutuv.Social.Block do
  @moduledoc """
  One member blocking another (`Vutuv.Social.block_user/2`): a one-row
  capability cut, never built from user params directly. `conversation_id`
  remembers which conversation this block froze, so unblocking only thaws
  its own freeze.
  """

  use VutuvWeb, :model

  schema "blocks" do
    belongs_to(:blocker, Vutuv.Accounts.User)
    belongs_to(:blocked, Vutuv.Accounts.User)
    belongs_to(:conversation, Vutuv.Chat.Conversation)

    timestamps(updated_at: false)
  end
end
