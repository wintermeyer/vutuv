defmodule VutuvWeb.Admin.AdController do
  @moduledoc """
  The ad review dashboard. Every booked ad starts unapproved and never
  serves until an admin approves it here (`Vutuv.Ads.approve_ad/2`); the
  booking lead time of three days exists exactly for this review. The page
  shows each upcoming ad in full - rendered ad text, booker, billing data -
  so the family-friendliness check happens on what visitors would see.
  """

  use VutuvWeb, :controller

  alias Vutuv.Ads
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    render(conn, "index.html",
      page_title: gettext("Ad review"),
      upcoming_ads: Ads.upcoming_ads(),
      past_ads: Ads.past_ads()
    )
  end

  def show(conn, %{"id" => id}) do
    case Ads.get_ad_by_id(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      ad ->
        render(conn, "show.html",
          ad: ad,
          page_title: gettext("Ad for %{day}", day: ad.day)
        )
    end
  end

  def approve(conn, %{"id" => id}) do
    case Ads.get_ad_by_id(id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      ad ->
        case Ads.approve_ad(ad, conn.assigns[:current_user]) do
          {:ok, approved} ->
            conn
            |> put_flash(
              :info,
              gettext("The ad for %{day} is approved and will run.", day: approved.day)
            )
            |> redirect(to: ~p"/admin/ads")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, gettext("The ad could not be approved."))
            |> redirect(to: ~p"/admin/ads")
        end
    end
  end
end
