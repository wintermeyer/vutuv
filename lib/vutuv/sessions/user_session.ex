defmodule Vutuv.Sessions.UserSession do
  @moduledoc """
  One signed-in browser session of a `Vutuv.Accounts.User`.

  The plaintext lookup token exists only in the signed session cookie; only its
  SHA-256 (`token_hash`) is stored here, the same shape as `Vutuv.ApiAuth.Token`
  — a leaked database dump mints no usable session. `user_agent`, `ip_address`
  and `approx_location` are the best-effort device fingerprint captured at login
  (see `Vutuv.Sessions` and `Vutuv.Geo`); `token_hash`, `user_id` and the
  timestamps are set programmatically, never cast from user input.

  `inserted_at` is when the device first signed in, `last_seen_at` is bumped
  (throttled) on each request, and `revoked_at` marks a session the owner logged
  out remotely — set, it fails on the device's next request.
  """

  use VutuvWeb, :model

  schema "user_sessions" do
    belongs_to(:user, Vutuv.Accounts.User)

    field(:token_hash, :string)
    field(:user_agent, :string)
    field(:ip_address, :string)
    field(:approx_location, :string)
    field(:last_seen_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)

    timestamps()
  end

  @doc false
  # The device fingerprint is the only user-influenced data, and it is read
  # from request headers, not a form, so there is nothing to validate beyond
  # capping the lengths the columns can hold.
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_agent, :ip_address, :approx_location, :last_seen_at])
    |> validate_length(:user_agent, max: 1000)
    |> validate_length(:ip_address, max: 100)
    |> validate_length(:approx_location, max: 200)
    |> unique_constraint(:token_hash)
  end
end
