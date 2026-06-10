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
    user = conn.assigns[:user]

    cond do
      not activated?(user) ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)

      hidden_for?(user, conn.assigns[:current_user], conn) ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)

      true ->
        conn
    end
  end

  defp activated?(%User{activated?: true}), do: true
  defp activated?(%User{activated?: nil}), do: true
  defp activated?(_), do: false

  defp hidden_for?(%User{} = user, viewer, conn) do
    Vutuv.Moderation.account_hidden?(user) and not bypass?(user, viewer, conn)
  end

  # The owner/admin bypass is for the HTML page only; an agent-format request
  # is the anonymous view and never bypasses.
  defp bypass?(user, viewer, conn) do
    not agent_format?(conn) and html_bypass?(user, viewer)
  end

  defp html_bypass?(%User{id: id}, %User{id: id}), do: true
  defp html_bypass?(_user, %User{admin?: true}), do: true
  defp html_bypass?(_user, _viewer), do: false

  defp agent_format?(conn) do
    conn.private[:vutuv_agent_format] != nil or conn.private[:vutuv_agent_accept] != nil
  end
end
