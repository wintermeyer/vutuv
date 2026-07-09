defmodule Vutuv.LoginCodes.UserTotp do
  @moduledoc """
  The authenticator-app (RFC 6238 TOTP) enrolment of a `Vutuv.Accounts.User`
  (issue #912) — at most one per member.

  The row is minted **unconfirmed** when the setup page shows the QR code, so
  the shared `secret` lives only here and never rides in the client-readable
  signed session cookie. Typing a first valid code sets `confirmed_at`; only a
  confirmed row is accepted at login. `last_used_at` is handed to NimbleTOTP as
  `since:` so a code can never be replayed within its 30-second window.

  Every field is set programmatically in `Vutuv.LoginCodes` — nothing is cast
  from request params, so there is no changeset.
  """

  use VutuvWeb, :model

  schema "user_totps" do
    belongs_to(:user, Vutuv.Accounts.User)

    field(:secret, :binary)
    field(:confirmed_at, :utc_datetime)
    field(:last_used_at, :utc_datetime)

    timestamps()
  end
end
