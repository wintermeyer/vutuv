defmodule Vutuv.WebPush.Subscription do
  @moduledoc """
  One browser's Web Push subscription for this installation's **own** app
  (issue #1729) — the installed-on-a-phone case, which has no OAuth token and
  therefore could not use `Vutuv.MastodonApi.PushSubscription`.

  It is keyed on the endpoint rather than on a credential, because that is what
  a subscription is: a browser profile's own address at its push service. The
  same phone signed in as somebody else re-registers the same endpoint, so the
  unique index moves the row to the new owner instead of leaving the previous
  member's notifications going to a device they signed out of.

  `device` is the label the settings list shows ("Safari on iPhone"), derived
  from the User-Agent by `Vutuv.Sessions.device_summary/1` — the same wording
  the device list under Sign-in & security already uses, so one phone is called
  one thing across the site.
  """

  use VutuvWeb, :model

  alias Vutuv.WebPush.Validations

  schema "web_push_subscriptions" do
    belongs_to(:user, Vutuv.Accounts.User)

    field(:endpoint, :string)
    field(:p256dh, :string)
    field(:auth, :string)
    field(:device, :string)

    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    # `user_id` is never cast: the owner is the signed-in member the controller
    # already resolved, not a field a request may name.
    |> cast(attrs, [:endpoint, :p256dh, :auth, :device])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> Validations.validate_keys()
    |> Validations.validate_endpoint()
    # varchar(255), and the label is built from a header a client writes.
    |> validate_length(:device, max: 255)
    |> unique_constraint(:endpoint)
  end
end
