defmodule VutuvWeb.Admin.AdController do
  @moduledoc """
  The ad review dashboard. Every booked ad starts unapproved and never
  serves until an admin approves it here (`Vutuv.Ads.approve_ad/2`); the
  booking lead time of three days exists exactly for this review. The page
  shows each upcoming ad in full - rendered ad text, booker, billing data -
  so the family-friendliness check happens on what visitors would see.
  """

  use VutuvWeb, :controller

  # Nothing to review while the ad system is switched off.
  plug(VutuvWeb.Plug.RequireAdsEnabled)

  alias Vutuv.Ads
  alias VutuvWeb.AdHTML
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    {upcoming, withdrawn} = Ads.upcoming_ads()

    render(conn, "index.html",
      page_title: gettext("Ad review"),
      upcoming_ads: upcoming,
      withdrawn_ads: withdrawn,
      past_ads: Ads.past_ads()
    )
  end

  def show(conn, %{"id" => id}) do
    with_ad(conn, id, [:user, :approved_by, :rejected_by, :cancelled_by], fn ad ->
      render(conn, "show.html",
        ad: ad,
        page_title: gettext("Ad for %{day}", day: day(ad))
      )
    end)
  end

  def approve(conn, %{"id" => id}) do
    with_ad(conn, id, fn ad ->
      case Ads.approve_ad(ad, conn.assigns[:current_user]) do
        {:ok, approved} ->
          back(
            conn,
            :info,
            gettext("The ad for %{day} is approved and will run.", day: day(approved))
          )

        {:error, _reason} ->
          back(conn, :error, gettext("The ad could not be approved."))
      end
    end)
  end

  # Turning an ad down needs a reason: the booker is told it.
  def reject(conn, %{"id" => id} = params) do
    with_ad(conn, id, fn ad ->
      case Ads.reject_ad(ad, conn.assigns[:current_user], params["reason"] || "") do
        {:ok, rejected} ->
          back(
            conn,
            :info,
            gettext("The ad for %{day} is rejected; the booker has been told why.",
              day: day(rejected)
            )
          )

        {:error, %Ecto.Changeset{}} ->
          back(conn, :error, gettext("Please give the booker a reason."))

        {:error, :not_pending} ->
          back(conn, :error, gettext("Only an ad that waits for approval can be rejected."))
      end
    end)
  end

  def cancel(conn, %{"id" => id}) do
    with_ad(conn, id, fn ad ->
      case Ads.cancel_ad(ad, conn.assigns[:current_user]) do
        {:ok, cancelled} ->
          back(
            conn,
            :info,
            gettext("The ad for %{day} is cancelled; the booker has been told.",
              day: day(cancelled)
            )
          )

        {:error, :not_pending} ->
          back(conn, :error, gettext("This ad can no longer be cancelled."))
      end
    end)
  end

  defp with_ad(conn, id, preloads \\ [], fun) do
    case Ads.get_ad_by_id(id, preloads) do
      nil -> ControllerHelpers.render_error(conn, 404)
      ad -> fun.(ad)
    end
  end

  defp back(conn, kind, message),
    do: conn |> put_flash(kind, message) |> redirect(to: ~p"/admin/ads")

  defp day(ad), do: AdHTML.day_label(ad.day)
end
