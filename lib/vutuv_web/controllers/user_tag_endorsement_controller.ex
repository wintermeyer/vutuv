defmodule VutuvWeb.UserTagEndorsementController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :user_tags,
    join: :tag,
    slug_param: "id",
    field: :slug,
    select: :id,
    assign: :user_tag_id
  )

  plug(VutuvWeb.Plug.RequireLoginOr404)

  alias VutuvWeb.ControllerHelpers

  def create(conn, _params) do
    # Through the Tags.create_endorsement/1 chokepoint so the tag's owner also
    # gets the live in-app notification.
    case Vutuv.Tags.create_endorsement(%{
           user_tag_id: conn.assigns[:user_tag_id],
           user_id: conn.assigns[:current_user_id]
         }) do
      {:ok, _user_tag_endorsement} ->
        conn
        |> put_flash(:info, gettext("Endorsement successful."))
        |> redirect(to: referrer_url(conn))

      {:error, _changeset} ->
        conn
        |> put_flash(:info, gettext("Endorsement unsuccessful."))
        |> redirect(to: referrer_url(conn))
    end
  end

  def delete(conn, _params) do
    Repo.one!(
      from(e in Vutuv.Tags.UserTagEndorsement,
        where:
          e.user_tag_id == ^conn.assigns[:user_tag_id] and
            e.user_id == ^conn.assigns[:current_user_id]
      )
    )
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    |> Repo.delete!()

    conn
    |> put_flash(:info, gettext("Unendorsed tag successfully."))
    |> redirect(to: referrer_url(conn))
  end

  defp referrer_url(conn) do
    ControllerHelpers.referrer_url(conn, ~p"/#{conn.assigns[:user]}")
  end
end
