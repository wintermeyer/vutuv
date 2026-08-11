defmodule VutuvWeb.TagFollowController do
  use VutuvWeb, :controller

  alias Vutuv.Organizations.Organization
  alias Vutuv.Tags
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.RequireLoginOr404)
  plug(:scrub_params, "tag_follow" when action in [:create])

  # While speaking for a page, the subscription belongs to the page (issue
  # #1336): it is the page's feed the topic would reach, not the person's.
  #
  # Following a tag is silent and low-stakes, so both paths just toggle the
  # subscription and return to where the member was (the tag page, or the feed
  # rail / settings list). The follower is always the session user, never trusted
  # from params, so a request cannot forge someone else's subscription. Both
  # `Tags.follow_tag/2` and `Tags.unfollow_tag/2` are idempotent and swallow a
  # bad/unknown id, so a double-submit or a tampered id is a no-op, not a 500 —
  # hence no flash on either path (the tag page's pill flips to its new state,
  # which is the confirmation the member needs).
  def create(conn, %{"tag_follow" => %{"tag_id" => tag_id}}) do
    case conn.assigns[:acting_as] do
      %Organization{} = page -> Tags.follow_tag_as_organization(page, tag_id)
      _member -> Tags.follow_tag(conn.assigns.current_user, tag_id)
    end

    redirect(conn, to: referrer_url(conn))
  end

  def delete(conn, %{"id" => tag_id}) do
    case conn.assigns[:acting_as] do
      %Organization{} = page -> Tags.unfollow_tag_as_organization(page, tag_id)
      _member -> Tags.unfollow_tag(conn.assigns.current_user, tag_id)
    end

    redirect(conn, to: referrer_url(conn))
  end

  defp referrer_url(conn) do
    ControllerHelpers.referrer_or_profile(conn, conn.assigns[:current_user])
  end
end
