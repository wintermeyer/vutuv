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

  alias Vutuv.Tags
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.UI

  def create(conn, _params) do
    # Through the Tags.create_endorsement/1 chokepoint so the tag's owner also
    # gets the live in-app notification.
    Tags.create_endorsement(%{
      user_tag_id: conn.assigns[:user_tag_id],
      user_id: conn.assigns[:current_user_id]
    })

    respond(conn, gettext("Endorsement successful."))
  end

  def delete(conn, _params) do
    Tags.delete_endorsement(conn.assigns[:user_tag_id], conn.assigns[:current_user_id])

    respond(conn, gettext("Unendorsed tag successfully."))
  end

  # The profile's upvote pill toggles over fetch (the `TagVote` enhancement in
  # app.js): for that AJAX request answer with the fresh visible count + this
  # viewer's state as JSON so the pill animates in place. A plain (no-JS) form
  # submit still gets the classic flash + redirect. State is read back from the
  # DB, so the response is correct whether the write succeeded, was a duplicate,
  # or raced another tab.
  defp respond(conn, flash) do
    user_tag_id = conn.assigns[:user_tag_id]

    if ajax?(conn) do
      json(conn, %{
        count: UI.compact_count(Tags.count_visible_endorsements(user_tag_id)),
        endorsed: Tags.endorsed?(user_tag_id, conn.assigns[:current_user_id])
      })
    else
      conn
      |> put_flash(:info, flash)
      |> redirect(to: referrer_url(conn))
    end
  end

  defp ajax?(conn), do: "fetch" in get_req_header(conn, "x-requested-with")

  defp referrer_url(conn) do
    ControllerHelpers.referrer_url(conn, ~p"/#{conn.assigns[:user]}")
  end
end
