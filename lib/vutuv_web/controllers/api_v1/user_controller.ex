defmodule VutuvWeb.ApiV1.UserController do
  @moduledoc """
  `GET /api/v1/users/:slug` — a member's profile doc, read through the
  authorizing user's eyes (the same visibility rules as the HTML page).
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.ApiV1.Problem

  plug(VutuvWeb.Plug.RequireScope, "profile:read")

  def show(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    with %User{} = user <- Accounts.get_user_by_slug(slug),
         true <- visible_to?(user, viewer) do
      VutuvWeb.ApiV1.send_json(conn, ProfileDoc.build(user, viewer: viewer))
    else
      _missing_or_hidden -> Problem.not_found(conn)
    end
  end

  # Mirrors VutuvWeb.Plug.EnsureActivated: never-activated accounts are
  # invisible to everyone; moderation-hidden accounts stay visible to
  # themselves and admins (the API reads through the viewer's eyes, so the
  # owner/admin bypass applies, unlike the anonymous .json sibling pages).
  defp visible_to?(user, viewer) do
    activated?(user) and (not Moderation.account_hidden?(user) or bypass?(user, viewer))
  end

  defp activated?(%User{activated?: true}), do: true
  defp activated?(%User{activated?: nil}), do: true
  defp activated?(_user), do: false

  defp bypass?(%User{id: id}, %User{id: id}), do: true
  defp bypass?(_user, %User{admin?: true}), do: true
  defp bypass?(_user, _viewer), do: false
end
