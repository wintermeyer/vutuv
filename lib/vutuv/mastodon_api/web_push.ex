defmodule Vutuv.MastodonApi.WebPush do
  @moduledoc """
  The phone-client adapter's view of Web Push. Everything below is
  `Vutuv.WebPush` — the crypto was never Mastodon-specific, and the installed
  web app pushes through the same code with no access token in sight (issue
  #1729).

  What is *not* shared is the switch. A push to a phone client is the phone
  client API, so `MASTODON_API_ENABLED=false` has to take it with it: a device
  that subscribed while the adapter was on must stop being pushed to when the
  operator switches the adapter off. A member's own installed app is unaffected
  by that switch and gates on `Vutuv.WebPush.enabled?/0` alone.
  """

  alias Vutuv.MastodonApi
  alias Vutuv.WebPush

  @doc "Whether the adapter may push: the operator's push switch AND its own."
  def enabled?, do: MastodonApi.enabled?() and WebPush.enabled?()

  @doc "The VAPID public key a client needs to create a subscription."
  def public_key, do: if(enabled?(), do: WebPush.public_key())

  @doc "Sends one push; see `Vutuv.WebPush.send/2`."
  def send(subscription, payload) do
    if enabled?(), do: WebPush.send(subscription, payload), else: {:error, :disabled}
  end

  @doc """
  Sends one push and prunes a subscription the service reports as dead; see
  `Vutuv.WebPush.push/2`. The gate is this module's own, so a device that
  subscribed before `MASTODON_API_ENABLED=false` is left alone rather than
  being deleted for an answer nobody asked for.
  """
  def push(subscription, payload) do
    if enabled?(), do: WebPush.push(subscription, payload), else: :ok
  end
end
