defmodule VutuvWeb.SessionHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/session/*")

  # dev_mailbox?/0 (the /sent_emails dev link toggle) lives in VutuvWeb.UI,
  # imported app-wide, so the session and page PIN templates share it.
end
