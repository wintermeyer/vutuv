defmodule VutuvWeb.Plug.EnsureActivated do
  @moduledoc """
  Withholds the slug-routed pages of accounts that must not be publicly visible,
  with an honest HTTP status per reason (issue #812):

    * a never-activated registration (the anti-spam gate) → **404**: it must
      stay indistinguishable from a non-existent account, so you cannot probe
      whether an email is registered;
    * a reversible moderation/deliverability hold (frozen pending review,
      suspended, unreachable) → **403 Forbidden**: the account exists and is
      withheld;
    * a permanently deactivated account → **410 Gone**.

  The owner and admins still reach a frozen profile's **HTML** (200) — the owner
  needs their banner and the case page, admins their review — but the
  agent-format siblings (`.md`/`.txt`/`.json`/`.vcf`, see `VutuvWeb.AgentDocs`)
  are the cache-safe anonymous view, so the bypass does not apply to them: a
  hidden account's docs carry the same withheld status for everyone, or an
  owner/admin fetch could prime a shared cache with a hidden profile. HTML and
  the siblings therefore always report the same status.
  """

  alias Vutuv.Accounts.User
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Plug.AgentFormat

  def init(opts) do
    opts
  end

  def call(conn, _opts) do
    case conn.assigns[:user] do
      %User{} = user ->
        # The rule itself lives in Vutuv.Moderation (shared with the API).
        # The owner/admin bypass is for the HTML page only; an agent-format
        # request is the anonymous view, so it gets viewer: nil.
        viewer = if AgentFormat.agent_format?(conn), do: nil, else: conn.assigns[:current_user]

        if Vutuv.Moderation.profile_visible_to?(user, viewer) do
          conn
        else
          withhold(conn, Vutuv.Moderation.withheld_status(user))
        end

      _missing ->
        ControllerHelpers.render_error(conn, 404)
    end
  end

  # A never-activated account keeps the anti-enumeration 404; a real-but-hidden
  # account gets the profile-unavailable page at its honest 403/410 status.
  defp withhold(conn, 404), do: ControllerHelpers.render_error(conn, 404)
  defp withhold(conn, status), do: ControllerHelpers.render_withheld_profile(conn, status)
end
