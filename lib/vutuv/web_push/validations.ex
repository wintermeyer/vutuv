defmodule Vutuv.WebPush.Validations do
  @moduledoc """
  The changeset rules a Web Push subscription obeys, wherever it came from.

  Today one schema writes them, `Vutuv.MastodonApi.PushSubscription`, for a
  phone client holding an access token. They live out here rather than in it
  because the values are not the adapter's: they are the three a browser's
  `PushManager` hands over, so any second subscriber — the installed app's own
  worker is the one coming (issue #1729) — owes exactly the same checks, and a
  check that lives inside one schema is a check the next one is one refactor
  away from losing.
  """

  import Ecto.Changeset

  alias Vutuv.Ssrf
  alias Vutuv.WebPush

  @doc """
  The endpoint: an https URL that is not an internal address.

  A subscription endpoint is a URL this installation will POST to, so it is
  the same shape of hazard as a webhook target: whoever writes it here picks
  where our server sends a request. https-only is not enough on its own —
  `https://10.0.0.5/` is a perfectly good https URL — so the literal check
  from `Vutuv.Ssrf` runs beside it, exactly as `Vutuv.Webhooks.Subscription`
  does. It is the cheap half of the pair and does no DNS, which is what makes
  it safe in a changeset; `Vutuv.WebPush` re-checks with resolution at send
  time, because a public hostname can be re-pointed at an internal address
  after this row is written.
  """
  def validate_endpoint(changeset) do
    validate_change(changeset, :endpoint, &endpoint_errors/2)
  end

  defp endpoint_errors(:endpoint, value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        internal_host_errors(host)

      _other ->
        [endpoint: "must be an https URL"]
    end
  end

  defp internal_host_errors(host) do
    if Ssrf.internal_host?(host),
      do: [endpoint: "must not point at a private, loopback or link-local address"],
      else: []
  end

  @doc """
  The two keys: base64url of fixed-size binaries — a 65-byte P-256 point and a
  16-byte secret.

  They are checked here because nothing downstream can. `Vutuv.WebPush`
  decodes them at delivery time, inside a fire-and-forget task, on **every**
  notification: an unusable key stored once is not one failed push, it is a
  task that dies again for as long as the row lives, and the member never
  learns why their phone is silent. The refusal belongs at the only point
  where somebody is still waiting for an answer.

  The length caps keep an oversized value out of a varchar(255) column, where
  Postgres would answer with a raised 22001 rather than a changeset error.
  """
  def validate_keys(changeset) do
    changeset
    |> validate_length(:p256dh, max: 255)
    |> validate_length(:auth, max: 255)
    |> validate_change(:p256dh, &validate_key(&1, &2, 65))
    |> validate_change(:auth, &validate_key(&1, &2, 16))
  end

  defp validate_key(field, value, bytes) do
    case WebPush.decode_key(value) do
      {:ok, decoded} when byte_size(decoded) == bytes -> []
      _undecodable_or_wrong_size -> [{field, "must be base64url of #{bytes} bytes"}]
    end
  end
end
