defmodule VutuvWeb.Api.VCardController do
  use VutuvWeb, :controller
  import Ecto.Query
  alias VutuvWeb.Api.VCardJSON

  plug(:assign_user)
  plug(:headers)

  def get(conn, _params) do
    vcard =
      conn.assigns[:user]
      |> Repo.preload([
        :addresses,
        :phone_numbers,
        social_media_accounts:
          from(s in Vutuv.Profiles.SocialMediaAccount, where: s.provider == ^"Twitter")
      ])
      |> preload_emails(conn.assigns[:current_user])

    # The vCard body is a plain text/vcard string (Content-Type and
    # Content-Disposition are set by the `headers` plug above). Send it
    # directly instead of going through Phoenix format/view resolution,
    # which only knows the :html and :json formats and cannot resolve a
    # "vcf" view — that mismatch raised a 500 at runtime.
    send_resp(conn, 200, VCardJSON.vcard(vcard))
  end

  defp preload_emails(user, requester) do
    if VutuvWeb.UserHelpers.user_has_permissions?(user, requester) do
      Repo.preload(user, [:emails])
    else
      user
    end
  end

  defp assign_user(conn, _opts) do
    conn = fetch_session(conn)
    user_id = get_session(conn, :user_id)
    user = user_id && Vutuv.Repo.get(Vutuv.Accounts.User, user_id)

    conn
    |> assign(:current_user, user)
  end

  defp headers(conn, _opts) do
    filename =
      "#{VutuvWeb.UserHelpers.first_and_last(conn.assigns[:user], "_") |> String.downcase()}_vcard.vcf"

    conn
    |> Plug.Conn.put_resp_content_type("text/vcard")
    |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
  end
end
