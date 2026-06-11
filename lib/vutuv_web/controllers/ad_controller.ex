defmodule VutuvWeb.AdController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin when action in [:new, :create])

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

  def new(conn, _params) do
    # Prefill the first bookable day; the date input's `min` mirrors it.
    changeset = Ads.change_ad(%Ads.Ad{day: Ads.next_available_day()})
    render_form(conn, changeset)
  end

  def create(conn, %{"ad" => ad_params}) do
    case Ads.book_ad(conn.assigns[:current_user], ad_params) do
      {:ok, ad} ->
        conn
        |> put_flash(
          :info,
          gettext(
            "Your ad for %{day} is booked. The day is reserved; the invoice follows by email.",
            day: ad.day
          )
        )
        |> redirect(to: ~p"/ads")

      {:error, changeset} ->
        render_form(conn, changeset)
    end
  end

  defp render_form(conn, changeset) do
    render(conn, "new.html",
      changeset: changeset,
      next_available_day: Ads.next_available_day(),
      page_title: gettext("Book your ad")
    )
  end
end
