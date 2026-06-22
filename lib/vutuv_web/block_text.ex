defmodule VutuvWeb.BlockText do
  @moduledoc """
  The two member-facing block strings in one place, so the long confirm prompt
  and the success flash stay identical across the profile header, the message
  thread and the `/blocks` controller. These wrap `gettext` (not a raw string
  passed in), so the msgids are still extracted here and the existing
  translations keep applying.
  """
  use Gettext, backend: VutuvWeb.Gettext

  @doc "The flash shown after a successful block."
  def blocked_flash(slug) do
    gettext("You blocked @%{slug}. You can undo this on your blocked list.", slug: slug)
  end

  @doc "The data-confirm prompt shown before blocking."
  def confirm(slug) do
    gettext(
      "Block @%{slug}? This removes any follows and connection between you, closes your conversation, and prevents all interaction in both directions. Unblocking will not restore what was removed.",
      slug: slug
    )
  end
end
