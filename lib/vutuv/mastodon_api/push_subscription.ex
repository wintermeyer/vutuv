defmodule Vutuv.MastodonApi.PushSubscription do
  @moduledoc """
  One device's Web Push subscription, keyed on the access token that created
  it — so a member with two phones has two, and revoking an app takes its
  subscription with it.
  """

  use VutuvWeb, :model

  alias Vutuv.MastodonApi.WebPush

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
    # The keys are base64url of a 65-byte point and a 16-byte secret; the length
    # caps keep an oversized value out of a varchar(255) column, where Postgres
    # would answer with a raised 22001 rather than a changeset error.
    |> validate_length(:p256dh, max: 255)
    |> validate_length(:auth, max: 255)
    |> validate_change(:p256dh, &validate_key(&1, &2, 65))
    |> validate_change(:auth, &validate_key(&1, &2, 16))
    |> validate_change(:endpoint, &validate_endpoint/2)
    |> update_change(:alerts, &normalize_alerts/1)
    |> unique_constraint(:api_token_id)
  end

  # A subscription endpoint is a URL this installation will POST to, so it must
  # be an https one and nothing else — an unvalidated endpoint would make the
  # push sender a request forwarder.
  defp validate_endpoint(:endpoint, value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
      _other -> [endpoint: "must be an https URL"]
    end
  end

  # The two keys are base64url of fixed-size binaries — a 65-byte P-256 point
  # and a 16-byte secret — and they are checked here because nothing downstream
  # can. `Vutuv.MastodonApi.WebPush` decodes them at delivery time, inside a
  # fire-and-forget task, on **every** notification: an unusable key stored once
  # is not one failed push, it is a task that dies again for as long as the row
  # lives, and the member never learns why their phone is silent. The refusal
  # belongs at the only point where somebody is still waiting for an answer.
  defp validate_key(field, value, bytes) do
    case WebPush.decode_key(value) do
      {:ok, decoded} when byte_size(decoded) == bytes -> []
      _undecodable_or_wrong_size -> [{field, "must be base64url of #{bytes} bytes"}]
    end
  end

  defp normalize_alerts(alerts) when is_map(alerts) do
    Map.new(@alert_kinds, fn kind -> {kind, truthy?(Map.get(alerts, kind, true))} end)
  end

  defp normalize_alerts(_other), do: Map.new(@alert_kinds, &{&1, true})

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
