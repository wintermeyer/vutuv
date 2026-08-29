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

    timestamps()
  end

  def alert_kinds, do: @alert_kinds

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :alerts])
    |> validate_required([:endpoint, :p256dh, :auth])
    # Shared with the installed app's own subscriptions, which store the same
    # three values from the same browser API; see `Vutuv.WebPush.Validations`
    # for why each check has to sit at this end.
    |> Validations.validate_keys()
    |> Validations.validate_endpoint()
    |> update_change(:alerts, &normalize_alerts/1)
    |> unique_constraint(:api_token_id)
  end

  defp normalize_alerts(alerts) when is_map(alerts) do
    Map.new(@alert_kinds, fn kind -> {kind, truthy?(Map.get(alerts, kind, true))} end)
  end

  defp normalize_alerts(_other), do: Map.new(@alert_kinds, &{&1, true})

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
