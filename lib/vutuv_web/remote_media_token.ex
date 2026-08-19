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
  only ever leaves the building inside an authenticated API response (every
  Mastodon route that renders an account sits behind `Plugs.MastodonApiAuth`;
  the few unauthenticated ones render no `%RemoteAccount{}`). And it widens
  nothing else — the AI gate and the stored-file whitelist are re-asked on
  every request, so a picture the gate takes back or a file that gets rotated
  stops answering with the capability still in hand.

  **What it does widen is *who*, and it is a bearer URL: say so rather than
  claiming otherwise.** It names no member, no device and no access token, so
  nothing that ends a member's access ends its own — a remote logout, a
  suspension, a revoked OAuth app all leave a URL already handed out answering
  until it expires. Closing that would mean naming a session inside the token
  and looking it up per image request, which the adapter cannot do anyway:
  `Vutuv.MastodonApi.Presenter.account/2` is handed a row, never a viewer. The
  trade is deliberate and it is sized to what is behind the door — one cached
  copy of a public avatar that its own server serves to anybody who asks, held
  here only because a member follows them. Do not reach for this shape for
  anything a member would call private; `post_image/2`, whose pictures carry a
  post's audience, keeps the session and must go on keeping it.

  `signed_at` is pinned to the UTC day rather than to the moment, so a client
  is handed the same URL all day and its image cache keeps working. A
  per-render timestamp would re-mint every avatar URL on every timeline
  refresh, and a client caches by URL — every face in the timeline would be
  downloaded again each time. `@max_age` is a day longer than the window a
  client may still be showing a cached timeline from, so the pinning can never
  hand out a capability that is already stale.

  **Avatars only — and that is where the work stopped, not where the problem
  ends.** Read the scope as two open gaps rather than as a boundary. The
  proxy's other route serves a cached post's attachments and
  `Vutuv.MastodonApi.Presenter.status/2` leaves `media_attachments` empty for a
  `%RemotePost{}` and a `%Note{}`, so a capability there would be dead code
  today — but only because a photo post from another network reaches a client
  with no photo at all (issue #1626), and fixing that brings the identical 404
  straight back. And the adapter *does* name local post photos, at
  `/post_images/…`, which asks `Posts.image_visible_to?/2`: fine for a public
  post, false for a restricted one against the nil viewer an image loader is,
  so those are broken images in every client right now (issue #1627). The
  subject is a tagged tuple so each of those is a second tag and a second pair
  of heads here, not a second module.
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

  `signed_at` is the injectable clock: expiry is the one property that makes
  this a capability rather than an unguessable URL, and a test that cannot mint
  an old capability cannot prove the expiry is wired up at all — nor tell a
  `max_age` that is enforced from one that was quietly dropped. Production
  passes nothing and gets `bucket/0`.
  """
  def avatar_query(account_id, file, signed_at \\ bucket())
      when is_binary(account_id) and is_binary(file) do
    token = Phoenix.Token.sign(Endpoint, @salt, {:avatar, account_id, file}, signed_at: signed_at)
    URI.encode_query(%{param() => token})
  end

  @doc "How long a capability stays good, in seconds."
  def max_age, do: @max_age

  @doc """
  Whether `token` is a capability this installation minted and has not expired
  — without saying which picture it opens.

  This is the half of the answer that needs no database row, and it exists so
  the proxy can turn away a caller who brings nothing unforgeable *before*
  looking an account up. A check on the token's shape could not do that (any
  non-empty string has the shape), so without this an anonymous request would
  cost a query, which the signed-in-only route never did. `avatar?/3` is still
  the real check: only the row knows which file the account holds now.
  """
  def authentic?(token) when is_binary(token) do
    match?(
      {:ok, {:avatar, _account_id, _file}},
      Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)
    )
  end

  def authentic?(_token), do: false

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
