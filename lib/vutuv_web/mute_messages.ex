defmodule VutuvWeb.MuteMessages do
  @moduledoc """
  What a member is told when a mute is placed, once for every surface that
  places one.

  Two of them do: the cached post card's ⋯ menu, which pushes a LiveView event
  (`VutuvWeb.Live.RemotePostActions`), and the CSRF route the local card's menu
  and `/settings/mutes` post to (`VutuvWeb.SettingsController`). They write the
  same row through the same function and had grown their own copy of each
  sentence — three pairs of identical `gettext` calls, which is three chances
  for the two menus to explain the same act differently.

  The scope decides the sentence, so a fourth one cannot be added without a
  clause here, and each says what stays as well as what goes: the whole point
  of the narrow scopes is that the account is still heard.
  """

  use Gettext, backend: VutuvWeb.Gettext

  @doc "The confirmation for a mute placed at `scope`."
  def flash(:reposts),
    do: gettext("Hidden. What they pass on stays out of your feed; their own posts do not.")

  def flash(:reposts_of) do
    gettext(
      "Hidden. What other people pass on of them stays out of your feed; their own posts do not."
    )
  end

  def flash(_all), do: gettext("Muted. Their posts leave your feed.")
end
