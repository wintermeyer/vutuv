defmodule VutuvWeb.AdController do
  use VutuvWeb, :controller

  # The whole public ad flow is dark while the system is switched off.
  plug(VutuvWeb.Plug.RequireAdsEnabled)
  plug(VutuvWeb.Plug.RequireLogin when action in [:new, :preview, :create, :bookings, :cancel])

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

  # The "edit again" leg of the preview step: re-render the form with what
  # was entered (no errors shown - the changeset carries no action).
  def new(conn, %{"ad" => ad_params} = params) do
    render_form(conn, Ads.change_ad(%Ads.Ad{}, ad_params), days(params))
  end

  def new(conn, _params) do
    # Prefill the first bookable day; the calendar marks it selected.
    changeset = Ads.change_ad(%Ads.Ad{day: Ads.next_available_day()})
    render_form(conn, changeset, 1)
  end

  # How many consecutive days this booking is for, from the length radios.
  # Anything that is not one of the offered lengths is a single day; a tampered
  # value can then only ever buy less than it paid for, never more.
  defp days(%{"days" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} -> if Ads.tier(days), do: days, else: 1
      _not_a_number -> 1
    end
  end

  defp days(_params), do: 1

  # The check before buying: validate everything (including day
  # availability), then show the ad exactly as the banner will render it,
  # with the order summary. Booking happens only on the confirm POST /system/ads.
  def preview(conn, %{"ad" => ad_params} = params) do
    days = days(params)

    case Ads.preview_ad(ad_params, days) do
      {:ok, ad} ->
        render(conn, "preview.html",
          ad: ad,
          days: days,
          # Only scalar fields are re-emitted as hidden inputs on the confirm
          # form; a tampered list/map value would crash the template stringify.
          ad_params: Map.filter(ad_params, fn {_k, v} -> is_binary(v) end),
          page_title: gettext("Preview your ad")
        )

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render_form(changeset, days)
    end
  end

  def create(conn, %{"ad" => ad_params} = params) do
    days = days(params)

    case Ads.book_ad(conn.assigns[:current_user], ad_params, days) do
      {:ok, ad} ->
        conn
        |> put_flash(:info, booked_flash(ad, days))
        |> redirect(to: ~p"/system/ads/bookings")

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render_form(changeset, days)
    end
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

  # A single day and a stretch of days are two sentences, not one sentence
  # with a range dropped into the slot a date was written for.
  defp booked_flash(ad, 1) do
    gettext(
      "Your ad for %{day} is booked. We will review and approve it shortly; the invoice follows by email.",
      day: AdHTML.day_label(ad.day)
    )
  end

  defp booked_flash(ad, days) do
    gettext(
      "Your ad is booked for %{period}. We will review and approve it shortly; the invoice follows by email.",
      period: AdHTML.period_label(ad.day, days)
    )
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

  defp render_form(conn, changeset, days) do
    render(conn, "new.html",
      changeset: changeset,
      days: days,
      next_available_day: Ads.next_available_day(),
      page_title: gettext("Book your ad")
    )
  end
end
