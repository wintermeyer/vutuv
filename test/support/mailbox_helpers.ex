defmodule Vutuv.MailboxHelpers do
  @moduledoc """
  Test helpers for the Swoosh test adapter's process mailbox. Imported by
  `Vutuv.DataCase` and `VutuvWeb.ConnCase`.
  """

  @doc """
  Pops every `{:email, ...}` message delivered so far and returns the emails,
  oldest first. Use it to assert across flows that send several emails
  (Swoosh's `assert_email_sent/1` pops strictly in order), or call it just to
  drain moderation notices before `login_via_pin/2` reads its PIN mail.
  """
  def flush_emails do
    receive do
      {:email, email} -> [email | flush_emails()]
    after
      0 -> []
    end
  end
end
