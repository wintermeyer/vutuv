defmodule VutuvWeb.RemoteMediaToken do
  @moduledoc """
  The capability that lets an **API client** load a picture cached from another
  network — the second door into `VutuvWeb.RemoteMediaController`, beside the
  signed-in reader it already knew.

  A phone app fetches an image with a bare `GET`. Its image loader carries
  neither the session cookie nor the OAuth token the API call itself used, and
  no header we could ask for would arrive — that is how every image loader on
  every platform works. So from v7.330.0, when the Mastodon adapter started
  naming the cached picture instead of the installation's icon, every account
  out of the fediverse came back 404 and sat blank in the app. The adapter now
  mints a capability for exactly that picture and the proxy takes it instead of
  a session.

  This is **not** the "unguessable URL" the proxy's moduledoc rightly refuses:
  it is unforgeable, it expires, it names one account's one stored file, and it
  only ever leaves the building inside an authenticated API response. And it
  widens nothing else — the AI gate and the stored-file whitelist are re-asked
  on every request, so a picture the gate takes back or a file that gets
  rotated stops answering with the capability still in hand.

  `signed_at` is pinned to the UTC day rather than to the moment, so a client
  is handed the same URL all day and its image cache keeps working. A
  per-render timestamp would re-mint every avatar URL on every timeline
  refresh, and a client caches by URL — every face in the timeline would be
  downloaded again each time. `@max_age` is a day longer than the window a
  client may still be showing a cached timeline from, so the pinning can never
  hand out a capability that is already stale.

  **Avatars only, and that is a decision rather than an oversight.** The proxy's
  other route serves a cached post's attachments, and the adapter never names
  one: `Vutuv.MastodonApi.Presenter.status/2` leaves `media_attachments` at the
  empty default for a `%RemotePost{}` and a `%Note{}`, so a capability there
  would be dead code today. The subject is a tagged tuple, so the day that
  changes is a second tag and a second pair of heads here — not a second module.
  """

  alias VutuvWeb.Endpoint

  @salt "remote media capability"
  @bucket 60 * 60 * 24
  @max_age 60 * 60 * 24 * 8

  @doc "The query-parameter name a capability travels in."
  def param, do: "t"

  @doc """
  The capability for one account's currently stored avatar, as the query string
  the adapter appends to the picture's URL.
  """
  def avatar_query(account_id, file) when is_binary(account_id) and is_binary(file) do
    token = Phoenix.Token.sign(Endpoint, @salt, {:avatar, account_id, file}, signed_at: bucket())
    URI.encode_query(%{param() => token})
  end

  @doc """
  Whether `token` opens exactly this account's exactly this file. Anything else
  — a made-up string, an expired one, one minted for another account or for the
  picture this row used to hold — is false, which the proxy answers as 404 like
  every other refusal it makes.
  """
  def avatar?(token, account_id, file)
      when is_binary(token) and is_binary(account_id) and is_binary(file) do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age) do
      {:ok, {:avatar, ^account_id, ^file}} -> true
      _other -> false
    end
  end

  # nil is the ordinary case on the website, where the session answers instead.
  def avatar?(_token, _account_id, _file), do: false

  # The start of the current UTC day, in the seconds `Phoenix.Token` wants.
  defp bucket, do: div(System.os_time(:second), @bucket) * @bucket
end
