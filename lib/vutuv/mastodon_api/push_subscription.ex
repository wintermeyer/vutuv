defmodule Vutuv.MastodonApi.PushSubscription do
  @moduledoc """
  One device's Web Push subscription, keyed on the access token that created
  it — so a member with two phones has two, and revoking an app takes its
  subscription with it.
  """

  use VutuvWeb, :model

  alias Vutuv.WebPush.Validations

  @alert_kinds ~w(mention favourite reblog follow)

  schema "mastodon_push_subscriptions" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:api_token, Vutuv.ApiAuth.Token)

    field(:endpoint, :string)
    field(:p256dh, :string)
    field(:auth, :string)
    field(:alerts, :map, default: %{})

    # Whether this device's client asked for the standard content encoding.
    # False is Mastodon's own default and therefore ours; what the two
    # encodings are, and why a phone needs the older one, is in
    # `Vutuv.WebPush`, which reads this field through `content_encoding/1`.
    field(:standard, :boolean, default: false)

    timestamps()
  end

  def alert_kinds, do: @alert_kinds

  def changeset(subscription, attrs) do
    subscription
    |> cast(normalize_standard(attrs), [:endpoint, :p256dh, :auth, :alerts, :standard])
    |> validate_required([:endpoint, :p256dh, :auth])
    # Shared with the installed app's own subscriptions, which store the same
    # three values from the same browser API; see `Vutuv.WebPush.Validations`
    # for why each check has to sit at this end.
    |> Validations.validate_keys()
    |> Validations.validate_endpoint()
    |> update_change(:alerts, &normalize_alerts/1)
    |> unique_constraint(:api_token_id)
  end

  # A client spells the flag however its HTTP library felt like — `true`, the
  # string `"true"`, `"1"` — and a value Ecto refuses to cast would answer 422
  # to a subscription that is otherwise perfectly good, leaving that device
  # with no push at all.
  #
  # **Before `cast/3`, and that asymmetry with `normalize_alerts/1` below is
  # load-bearing**: `alerts` is a `:map` field, so anything survives the cast
  # and `update_change/3` can tidy it afterwards, while `"0"` against a
  # `:boolean` field is refused *by* the cast — an `update_change/3` here would
  # never run and would quietly restore the 422 this exists to prevent.
  defp normalize_standard(%{"standard" => value} = attrs),
    do: Map.put(attrs, "standard", truthy?(value))

  defp normalize_standard(attrs), do: attrs

  defp normalize_alerts(alerts) when is_map(alerts) do
    Map.new(@alert_kinds, fn kind -> {kind, truthy?(Map.get(alerts, kind, true))} end)
  end

  defp normalize_alerts(_other), do: Map.new(@alert_kinds, &{&1, true})

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
