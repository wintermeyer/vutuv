defmodule VutuvWeb.Presence do
  @moduledoc """
  Tracks who is online (and, later, who is typing) for the real-time messaging
  shell. Backed by the already-running `Vutuv.PubSub`.
  """
  use Phoenix.Presence,
    otp_app: :vutuv,
    pubsub_server: Vutuv.PubSub
end
