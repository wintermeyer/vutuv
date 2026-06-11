defmodule VutuvWeb.VCardController do
  @moduledoc """
  The session-aware vCard download (`/:slug/vcard`). The profile's
  canonical, cache-safe vCard lives at `/:slug.vcf` (see
  `VutuvWeb.AgentDocs`); this route keeps the one historical extra the
  profile's download link relies on: a viewer the member follows back (or
  the member themselves) gets **all** email addresses, not just the
  public ones. Ported from the deleted `/api/1.0` namespace.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.VCard

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
