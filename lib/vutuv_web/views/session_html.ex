defmodule VutuvWeb.SessionHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/session/*")

  # dev_mailbox?/0 (the /sent_emails dev link toggle) lives in VutuvWeb.UI,
  # imported app-wide, so the session and page PIN templates share it.

  @doc """
  Whether the PIN screen should add its one-line reminder that a code from an
  authenticator app or a one-time code list also works (issue #912). Reads
  the pending identity from the signed cookie — the same source every render
  site of pin_user_login.html already relies on, so the hint needs no assign
  threaded through the five controllers/plugs that render the form.

  Only members who actually enrolled see the line, so normal members never
  meet it. The deliberate cost (mirroring the passkey fallback, issue #834):
  the tailored screen reveals that the typed address has an enrolled account.
  """
  def alternative_codes?(conn) do
    case Vutuv.Accounts.read_pin_cookie(conn) do
      email when is_binary(email) -> Vutuv.LoginCodes.any_for_email?(email)
      _ -> false
    end
  end
end
