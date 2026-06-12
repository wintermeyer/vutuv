defmodule VutuvWeb.AdController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin when action in [:new, :preview, :create, :bookings])

  alias Vutuv.Ads
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.AdsDoc

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
  def new(conn, %{"ad" => ad_params}) do
    render_form(conn, Ads.change_ad(%Ads.Ad{}, ad_params))
  end

  def new(conn, _params) do
    # Prefill the first bookable day; the calendar marks it selected.
    changeset = Ads.change_ad(%Ads.Ad{day: Ads.next_available_day()})
    render_form(conn, changeset)
  end

  # The check before buying: validate everything (including day
  # availability), then show the ad exactly as the banner will render it,
  # with the order summary. Booking happens only on the confirm POST /ads.
  def preview(conn, %{"ad" => ad_params}) do
    case Ads.preview_ad(ad_params) do
      {:ok, ad} ->
        render(conn, "preview.html",
          ad: ad,
          ad_params: ad_params,
          page_title: gettext("Preview your ad")
        )

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render_form(changeset)
    end
  end

  def create(conn, %{"ad" => ad_params}) do
    case Ads.book_ad(conn.assigns[:current_user], ad_params) do
      {:ok, ad} ->
        conn
        |> put_flash(
          :info,
          gettext(
            "Your ad for %{day} is booked. We will review and approve it shortly; the invoice follows by email.",
            day: ad.day
          )
        )
        |> redirect(to: ~p"/ads/bookings")

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render_form(changeset)
    end
  end

  # The member's booking dashboard: every booked day with its approval state.
  def bookings(conn, _params) do
    render(conn, "bookings.html",
      ads: Ads.user_ads(conn.assigns[:current_user]),
      page_title: gettext("My ad bookings")
    )
  end

  defp render_form(conn, changeset) do
    render(conn, "new.html",
      changeset: changeset,
      next_available_day: Ads.next_available_day(),
      page_title: gettext("Book your ad")
    )
  end
end
