defmodule Vutuv.ChatHelpers do
  @moduledoc false

  alias Vutuv.Chat
  alias Vutuv.Chat.Message

  @doc """
  Sends `body` from `sender` into `conversation`, unwrapping the
  `{:ok, %Message{}}` tuple so tests can use the message directly.
  """
  def send!(sender, conversation, body \\ "hi") do
    {:ok, %Message{} = message} = Chat.send_message(sender, conversation.id, body)
    message
  end
end
