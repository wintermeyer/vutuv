defmodule VutuvWeb.AdController do
  use VutuvWeb, :controller

  # The whole public ad flow is dark while the system is switched off.
  plug(VutuvWeb.Plug.RequireAdsEnabled)
  plug(VutuvWeb.Plug.RequireLogin when action in [:bookings, :cancel])

  alias Vutuv.Ads
  alias VutuvWeb.AdHTML
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.AdsDoc
  alias VutuvWeb.ControllerHelpers

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.AdsDoc.
  # Keep index.html and the doc builder in sync (the controller test's
  # "no drift" block checks the shared facts).
  def index(conn, _params) do
    next_available_day = Ads.next_available_day()

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          next_available_day: next_available_day,
          page_title: gettext("Advertising")
        )
      end,
      doc: fn -> AdsDoc.build(next_available_day) end
    )
  end

  # The member's booking dashboard: every booked day with its approval state.
  def bookings(conn, _params) do
    render(conn, "bookings.html",
      bookings: Ads.user_bookings(conn.assigns[:current_user]),
      page_title: gettext("My ad bookings")
    )
  end

  # A booking waiting for approval may be withdrawn by its booker; once
  # approved it is binding. Somebody else's booking is not there for them.
  def cancel(conn, %{"id" => id}) do
    with %Ads.Ad{} = ad <- Ads.get_ad_by_id(id),
         {:ok, cancelled} <- Ads.cancel_booking(ad, conn.assigns[:current_user]) do
      conn
      |> put_flash(:info, cancelled_flash(cancelled, Ads.purchase_days(cancelled)))
      |> redirect(to: ~p"/system/ads/bookings")
    else
      {:error, :not_pending} ->
        conn
        |> put_flash(
          :error,
          gettext("An approved booking is binding and can no longer be cancelled here.")
        )
        |> redirect(to: ~p"/system/ads/bookings")

      _missing_or_foreign ->
        ControllerHelpers.render_error(conn, 404)
    end
  end

  defp cancelled_flash(ad, 1) do
    gettext("Your ad for %{day} is cancelled, and the day is free again.",
      day: AdHTML.day_label(ad.day)
    )
  end

  defp cancelled_flash(ad, days) do
    gettext("Your ad for %{period} is cancelled, and those days are free again.",
      period: AdHTML.period_label(ad.day, days)
    )
  end
end
