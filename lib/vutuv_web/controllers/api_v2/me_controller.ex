defmodule VutuvWeb.ApiV2.MeController do
  @moduledoc """
  `GET /api/2.0/me` — the authorized user's own profile, through their own
  eyes (private emails and viewer-dependent posts included).

  `PATCH /api/2.0/me` — update the plain profile fields. The username
  (quota'd, Twitter-validated), email addresses (PIN-verified identities)
  and account flags deliberately stay out of the API's reach.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  def show(conn, _params) do
    user = conn.assigns.current_user
    ApiV2.send_json(conn, ProfileDoc.build(user, viewer: user))
  end

  def update(conn, params) do
    user = conn.assigns.current_user

    case Accounts.update_profile(user, params) do
      {:ok, user} -> ApiV2.send_json(conn, ProfileDoc.build(user, viewer: user))
      {:error, changeset} -> Problem.validation_failed(conn, changeset)
    end
  end
end
