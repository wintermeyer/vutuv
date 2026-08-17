defmodule Vutuv.ApiAuth.AppToken do
  @moduledoc """
  A bearer credential that belongs to an **app** and to no member — RFC 6749's
  `client_credentials` grant, which Mastodon's token endpoint answers.

  A Mastodon client asks for one immediately after registering itself through
  `POST /api/v1/apps`, before it sends anybody to a browser, and gives up if the
  request is refused. That is what `unsupported_grant_type` did to Ivory on a
  real phone.

  **Its own table, deliberately.** `Vutuv.ApiAuth.Token` requires a `user_id`
  and `Vutuv.ApiAuth.lookup/1` reaches the member through an inner join, so a
  userless row there would be swallowed by that join in silence. Keeping these
  apart also buys the security property outright: every member-scoped endpoint
  authenticates through `api_tokens`, so an app token cannot be accepted by one
  — not because something refuses it, but because it is not in the table that
  path reads. Nothing has to remember a rule.

  What it may do is correspondingly small: identify the app to
  `GET /api/v1/apps/verify_credentials`, and nothing else. It carries the app's
  registered scopes because Mastodon's response does, not because they grant
  anything here.

  The plaintext exists only in the moment of minting; `token_hash` is its
  SHA-256 and the only thing stored. A bare hash is right for it: the token is
  ~165 bits of randomness, so entropy rather than a key is what protects it
  (unlike a hash of anything guessable — see CLAUDE.md).
  """

  use VutuvWeb, :model

  schema "oauth_app_tokens" do
    belongs_to(:app, Vutuv.ApiAuth.App)

    field(:token_hash, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:last_used_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)

    timestamps()
  end

  @doc "Whether this token is still usable."
  def live?(%__MODULE__{revoked_at: nil}), do: true
  def live?(%__MODULE__{}), do: false
end
