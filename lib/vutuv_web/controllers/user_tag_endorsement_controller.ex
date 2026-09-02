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
    result =
      Tags.create_endorsement(%{
        user_tag_id: conn.assigns[:user_tag_id],
        user_id: conn.assigns[:current_user_id]
      })

    respond(conn, create_flash(result))
  end

  # The chokepoint refuses an honor tag, your own tag and a vouch across a block,
  # and the no-JS path used to claim success for all three. One wording for every
  # refusal on purpose: naming the block would tell the blocked member it exists,
  # which is precisely what a block is not supposed to announce. The AJAX branch
  # needs none of this — it reads the true state back from the database.
  defp create_flash({:ok, _endorsement}), do: {:info, gettext("Endorsement successful.")}
  defp create_flash({:error, _reason}), do: {:error, gettext("That endorsement is not possible.")}

  def delete(conn, _params) do
    Tags.delete_endorsement(conn.assigns[:user_tag_id], conn.assigns[:current_user_id])

    respond(conn, {:info, gettext("Unendorsed tag successfully.")})
  end

  # The profile's upvote pill toggles over fetch (the `TagVote` enhancement in
  # app.js): for that AJAX request answer with the fresh visible count + this
  # viewer's state as JSON so the pill animates in place. A plain (no-JS) form
  # submit still gets the classic flash + redirect. State is read back from the
  # DB, so the response is correct whether the write succeeded, was a duplicate,
  # or raced another tab.
  defp respond(conn, {kind, flash}) do
    user_tag_id = conn.assigns[:user_tag_id]

    if ajax?(conn) do
      json(conn, %{
        count: UI.compact_count(Tags.count_visible_endorsements(user_tag_id)),
        endorsed: Tags.endorsed?(user_tag_id, conn.assigns[:current_user_id])
      })
    else
      conn
      |> put_flash(kind, flash)
      |> redirect(to: referrer_url(conn))
    end
  end

  defp ajax?(conn), do: "fetch" in get_req_header(conn, "x-requested-with")

  defp referrer_url(conn) do
    ControllerHelpers.referrer_url(conn, ~p"/#{conn.assigns[:user]}")
  end
end
