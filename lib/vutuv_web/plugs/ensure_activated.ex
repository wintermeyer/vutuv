defmodule VutuvWeb.Plug.EnsureActivated do
  @moduledoc """
  404s the slug-routed pages of accounts that must not be publicly visible:
  never-activated registrations (the anti-spam gate) and accounts hidden by
  moderation (frozen pending review, suspended, deactivated). The owner and
  admins still reach a frozen profile's **HTML** — the owner needs their
  banner and the case page, admins their review — but the agent-format
  siblings (`.md`/`.txt`/`.json`/`.vcf`, see `VutuvWeb.AgentDocs`) are the
  cache-safe anonymous view, so the bypass does not apply to them: a hidden
  account's docs 404 for everyone, or an owner/admin fetch could prime a
  shared cache with a hidden profile.
  """

  alias Vutuv.Accounts.User

  def init(opts) do
    opts
  end

  def call(conn, _opts) do
    case conn.assigns[:user] do
      %User{} = user ->
        # The rule itself lives in Vutuv.Moderation (shared with the API).
        # The owner/admin bypass is for the HTML page only; an agent-format
        # request is the anonymous view, so it gets viewer: nil.
        viewer = if agent_format?(conn), do: nil, else: conn.assigns[:current_user]

        if Vutuv.Moderation.profile_visible_to?(user, viewer) do
          conn
        else
          VutuvWeb.ControllerHelpers.render_error(conn, 404)
        end

      _missing ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  defp agent_format?(conn) do
    conn.private[:vutuv_agent_format] != nil or conn.private[:vutuv_agent_accept] != nil
  end
end
