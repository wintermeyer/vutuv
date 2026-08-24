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
  nothing else — the AI gate, the stored-file whitelist and (for a photograph) the
  post's own audience are re-asked on every request, so a picture the gate takes
  back, a file that gets rotated and a post whose audience narrows all stop
  answering with the capability still in hand.

  **What it does widen is *who*, and it is a bearer URL: say so rather than
  claiming otherwise.** It names no member, no device and no access token, so
  nothing that ends a member's access ends its own — a remote logout, a
  suspension, a revoked OAuth app all leave a URL already handed out answering
  until it expires. Closing that would mean naming a session inside the token
  and looking it up per image request, which the adapter cannot do anyway:
  `Vutuv.MastodonApi.Presenter.account/2` is handed a row, never a viewer. The
  trade is deliberate and it is sized to what is behind the door — one cached
  copy of a public avatar that its own server serves to anybody who asks, held
  here only because a member follows them. Do not reach for *this* shape for
  anything a member would call private — the photograph tags below carry a
  post's audience and are bound to a member for exactly that reason.

  `signed_at` is pinned to the UTC day rather than to the moment, so a client
  is handed the same URL all day and its image cache keeps working. A
  per-render timestamp would re-mint every avatar URL on every timeline
  refresh, and a client caches by URL — every face in the timeline would be
  downloaded again each time. `@max_age` is a day longer than the window a
  client may still be showing a cached timeline from, so the pinning can never
  hand out a capability that is already stale.

  **A photograph is not an avatar, so its capability names the member it was
  minted for** (issues #1626 and #1627). The two picture tags added here open
  files that carry a *post's* audience — a member's photo on a post they
  narrowed, a photograph on a followers-only post cached from another network —
  and the bearer trade above is not sized for those. So each of them carries the
  id of the member the adapter rendered it for, and the proxy re-asks that
  member's own audience question (`Vutuv.Posts.image_visible_to?/2`,
  `Vutuv.Fediverse.remote_image_visible?/2`) on every request. A URL that leaves
  the member's hands still opens the picture — it is a URL — but the moment the
  author narrows the post, or takes the reader out of the audience, it stops
  answering for everybody holding it. The avatar tag keeps its simpler shape
  because it is sized for a public picture; do not copy *it* for anything else.

  What that costs is one `users` row per image request on the capability path,
  which is what the paragraph above said it would; the session path never pays
  it. And it *is* a standing check, not only an audience one: `holder/1` asks
  `Vutuv.Moderation.login_block/1` the way the session plug and the bearer
  check do, so a suspension closes a photograph capability the same day it
  closes everything else. Three tags, then, one clock and one salt.
  """

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
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
      when is_binary(account_id) and is_binary(file),
      do: sign_query({:avatar, account_id, file}, signed_at)

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
    case verify(token) do
      {:ok, {:avatar, _account_id, _file}} -> true
      {:ok, {:post_image, _image_token, _user_id}} -> true
      {:ok, {:remote_image, _image_id, _file, _user_id}} -> true
      _not_ours -> false
    end
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
    case verify(token) do
      {:ok, {:avatar, ^account_id, ^file}} -> true
      _other -> false
    end
  end

  # nil is the ordinary case on the website, where the session answers instead.
  def avatar?(_token, _account_id, _file), do: false

  @doc """
  The capability for one **local** post photo, as the query string the adapter
  appends to every version's URL.

  Keyed on the image's own URL token rather than on a version, so the one
  capability opens the sizes a client asks for; which member it opens them *as*
  is the whole point, and `post_image_viewer/2` reads that back.
  """
  def post_image_query(image_token, user_id, signed_at \\ bucket())
      when is_binary(image_token) and is_binary(user_id),
      do: sign_query({:post_image, image_token, user_id}, signed_at)

  @doc """
  The id of the member `token` was minted for on exactly this post photo, or
  `nil`. The caller asks that member's own audience question — the capability
  says who is at the door, never that the door is open.
  """
  def post_image_viewer(token, image_token)
      when is_binary(token) and is_binary(image_token) do
    case verify(token) do
      {:ok, {:post_image, ^image_token, user_id}} -> user_id
      _other -> nil
    end
  end

  def post_image_viewer(_token, _image_token), do: nil

  @doc """
  The same for a photograph cached from another network, pinned to the stored
  file the way `avatar_query/3` is: a picture the gate rejects and re-fetches
  stops answering at its old URL.
  """
  def remote_image_query(image_id, file, user_id, signed_at \\ bucket())
      when is_binary(image_id) and is_binary(file) and is_binary(user_id),
      do: sign_query({:remote_image, image_id, file, user_id}, signed_at)

  @doc "The member `token` was minted for on exactly this cached photograph, or `nil`."
  def remote_image_viewer(token, image_id, file)
      when is_binary(token) and is_binary(image_id) and is_binary(file) do
    case verify(token) do
      {:ok, {:remote_image, ^image_id, ^file, user_id}} -> user_id
      _other -> nil
    end
  end

  def remote_image_viewer(_token, _image_id, _file), do: nil

  @doc """
  The member a `*_viewer` answer names, or `nil` — including for the `nil` those
  functions return, so a caller reads as
  `session_member || holder(post_image_viewer(...))`.

  Here rather than in each proxy because it is the second half of one sentence:
  a photograph's capability says who is knocking, and this is who that is. The
  proxy then asks *its* picture's own audience question of them.

  **It asks `Moderation.login_block/1` first, which is what keeps the answer
  honest.** The other two doors into this application already do — the session
  plug drops a suspended member's session and `Vutuv.ApiAuth` refuses their
  bearer — and a capability that skipped it would be the one credential a
  suspension does not reach: a member suspended over the very people whose
  restricted photographs they hold URLs for would go on loading them until the
  URL expired. The row is in hand by then, so the check is free.
  """
  def holder(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %User{} = member -> if is_nil(Moderation.login_block(member)), do: member
      nil -> nil
    end
  end

  def holder(_no_capability), do: nil

  defp sign_query(subject, signed_at) do
    token = Phoenix.Token.sign(Endpoint, @salt, subject, signed_at: signed_at)
    URI.encode_query(%{param() => token})
  end

  defp verify(token), do: Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)

  # The start of the current UTC day, in the seconds `Phoenix.Token` wants.
  defp bucket, do: div(System.os_time(:second), @bucket) * @bucket
end
