defmodule VutuvWeb.InvitationController do
  @moduledoc """
  Invite-a-friend: a logged-in member fills what would be the invited person's
  sign-up (gender, name, tags, email) plus an optional note, and vutuv emails a
  link that opens the sign-up form prefilled with that data.

  All the real work — normalizing and hashing the address, the "invite each
  address once" rule, the per-inviter daily cap, and sending — lives in
  `Vutuv.Invitations`. The controller only turns its outcomes into flashes,
  always with the same neutral confirmation whether or not the address had been
  invited before (so the sender can't learn that it was).
  """
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.NoIndex)

  alias Vutuv.Invitations

  @page_title "Invite a friend"

  def new(conn, _params) do
    render_form(conn, Invitations.change_invitation_request(%{"locale" => default_locale(conn)}))
  end

  def create(conn, %{"invitation_request" => params}) do
    case Invitations.deliver_invitation(conn.assigns.current_user, params) do
      {:ok, _sent_or_already, preview} ->
        # Show the inviter exactly what the recipient receives (the built email),
        # which reads far better than dropping them back on an empty form.
        render(conn, "sent.html", page_title: gettext("Invitation sent"), preview: preview)

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> put_flash(:error, rate_limited_flash())
        |> render_form(Invitations.change_invitation_request(params))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_form(changeset)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render_form(Invitations.change_invitation_request())
  end

  defp render_form(conn, changeset) do
    render(conn, "new.html",
      page_title: gettext(@page_title),
      changeset: changeset,
      daily_cap: Invitations.daily_cap()
    )
  end

  defp rate_limited_flash do
    gettext("You have reached today's invitation limit. Please try again tomorrow.")
  end

  # Default the invitation's language to the sender's current UI language.
  defp default_locale(conn) do
    case Map.get(conn.assigns, :locale) do
      locale when locale in ["en", "de"] -> locale
      _ -> "en"
    end
  end
end
