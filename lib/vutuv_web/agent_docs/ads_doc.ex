defmodule VutuvWeb.AgentDocs.AdsDoc do
  @moduledoc """
  The `/system/ads` offer page (the daily text ad, see `Vutuv.Ads`) as a data map
  for the agent formats. `rules/0` and `price_display/0` are also what the
  HTML template renders, so the page and its docs cannot drift apart.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad
  alias VutuvWeb.AgentDocs

  @doc "The conditions list, shared verbatim by index.html.heex."
  def rules do
    [
      gettext(
        "Shown on profiles and in the feed: beside the content on a desktop, near the top on a phone."
      ),
      gettext(
        "Signed-in members see at most one ad an hour and none for the rest of the day once they close one. Visitors without an account see it on every profile they open. Each card goes again after two minutes in view."
      ),
      gettext(
        "Text only: a title of up to %{title} characters, one sentence of up to %{body} and a link, always clearly labeled as an ad.",
        title: Ad.title_max_length(),
        body: Ad.body_max_length()
      ),
      gettext("Ads must be family-friendly and follow the community guidelines."),
      gettext(
        "Every ad is reviewed and approved before it runs; the earliest bookable day is three days out."
      ),
      gettext("Booked online by logged-in members. Payment by invoice.")
    ]
  end

  @doc "The localized price line, shared verbatim by index.html.heex."
  def price_display do
    gettext("%{amount} € per day (net)",
      amount: VutuvWeb.UI.delimited_count(div(Ads.price_cents(), 100))
    )
  end

  @doc "The /system/ads page as a doc map."
  def build(next_available_day) do
    AgentDocs.doc_meta("advertising", "/system/ads")
    |> Map.merge(%{
      title: gettext("Advertising on vutuv"),
      description: gettext("One text-only ad per calendar day, seen by every visitor."),
      price: %{
        cents: Ads.price_cents(),
        currency: "EUR",
        net: true,
        display: price_display()
      },
      rules: rules(),
      next_available_day: next_available_day,
      booking_window: %{from: Ads.first_bookable_day(), to: Ads.last_bookable_day()},
      booked_days: Enum.sort(Ads.booked_days(), Date),
      booking_url: AgentDocs.abs_url("/system/ads/new"),
      community_guidelines_url: AgentDocs.abs_url("/community")
    })
  end
end
