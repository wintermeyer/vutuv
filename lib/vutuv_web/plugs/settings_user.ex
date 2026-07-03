defmodule VutuvWeb.Plug.SettingsUser do
  @moduledoc """
  Assigns the logged-in member as `:user` for the user-agnostic `/settings`
  scope. Every `/settings/*` page operates on whoever is signed in — there is
  no slug in the URL — so the same link (say, vutuv.de/settings/links) can be
  sent to any member and always opens *their own* editor, while the
  `/:slug/...` twins stay the public showcase view. Must run behind
  `RequireLogin` (which guarantees `:current_user`).
  """

  def init(opts), do: opts

  def call(conn, _opts), do: Plug.Conn.assign(conn, :user, conn.assigns[:current_user])
end
