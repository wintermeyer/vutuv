defmodule VutuvWeb.Plug.EnsureActivated do
  @moduledoc """
  404s the slug-routed pages of accounts that must not be publicly visible:
  never-activated registrations (the anti-spam gate) and accounts hidden by
  moderation (frozen pending review, suspended, deactivated). The owner and
  admins still reach a frozen profile — the owner needs their banner and the
  case page, admins their review.
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

      hidden_for?(user, conn.assigns[:current_user]) ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)

      true ->
        conn
    end
  end

  defp activated?(%User{activated?: true}), do: true
  defp activated?(%User{activated?: nil}), do: true
  defp activated?(_), do: false

  defp hidden_for?(%User{} = user, viewer) do
    Vutuv.Moderation.account_hidden?(user) and not bypass?(user, viewer)
  end

  defp bypass?(%User{id: id}, %User{id: id}), do: true
  defp bypass?(_user, %User{admin?: true}), do: true
  defp bypass?(_user, _viewer), do: false
end
