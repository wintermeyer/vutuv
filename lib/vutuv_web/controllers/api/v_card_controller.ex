defmodule VutuvWeb.Api.VCardController do
  @moduledoc """
  The legacy vCard URL (`/api/1.0/users/:slug/vcard`). The profile's
  canonical vCard now lives at `/:slug.vcf` (see `VutuvWeb.AgentDocs`); this
  route stays as an alias and keeps its one historical extra: a viewer the
  member follows back (or the member themselves) gets **all** email
  addresses, not just the public ones.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.VCard

  # The :api pipeline does not fetch the session, so do it here, then reuse
  # the shared session-user plug instead of re-implementing it.
  plug(:fetch_session)
  plug(VutuvWeb.Plug.ConfigureSession, repo: Vutuv.Repo)

  def get(conn, _params) do
    user = conn.assigns[:user]

    doc =
      ProfileDoc.build(user,
        include_photo: true,
        emails: visible_emails(user, conn.assigns[:current_user])
      )

    # Plain text/vcard, sent directly: Phoenix format/view resolution only
    # knows :html and :json and cannot resolve a "vcf" view.
    conn
    |> put_resp_content_type("text/vcard")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"#{VCard.filename(doc)}\""
    )
    |> send_resp(200, VCard.render(doc))
  end

  # The historical permission rule of this route: all addresses for a
  # permitted viewer, none otherwise (the public addresses are on /:slug.vcf).
  defp visible_emails(user, requester) do
    if VutuvWeb.UserHelpers.user_has_permissions?(user, requester) do
      user |> Ecto.assoc(:emails) |> Repo.all()
    else
      []
    end
  end
end
