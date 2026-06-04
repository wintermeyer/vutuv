defmodule VutuvWeb.SessionHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/session/*")

  # Dev convenience: in dev the Swoosh local adapter drops login PINs into the
  # mailbox preview at /sent_emails. The templates link there when this is on
  # (config/dev.exs); it stays off in test/prod where that route is absent.
  def dev_mailbox?, do: Application.get_env(:vutuv, :dev_mailbox, false)
end
