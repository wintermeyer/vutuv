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
  alias VutuvWeb.UI

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

  @doc """
  The localized price line, shared verbatim by index.html.heex: today's price,
  or the one a booking was made at.
  """
  def price_display(cents \\ Ads.price_cents()) do
    gettext("%{amount} € per day (net)", amount: UI.euro_cents(cents))
  end

  @doc """
  The price list: one row per bookable length (`Vutuv.Ads.tiers/0`), each as
  the sentence it is read as rather than as fragments a view glues together.
  `saving` is nil for the single day, which is the figure the others are
  measured against.
  """
  def tier_lines do
    Enum.map(Ads.tiers(), fn tier ->
      %{
        days: tier.days,
        cents: tier.cents,
        price:
          ngettext("One day for %{amount} €", "%{days} days for %{amount} €", tier.days,
            days: tier.days,
            amount: UI.euro_cents(tier.cents)
          ),
        saving: saving_line(tier)
      }
    end)
  end

  defp saving_line(%{days: 1}), do: nil

  defp saving_line(tier) do
    gettext("%{amount} € per day, %{percent} % less",
      amount: UI.euro_cents(Ads.tier_day_cents(tier)),
      percent: Ads.tier_discount_percent(tier)
    )
  end

  @doc """
  The VAT line under the price, or nil where the installation charges none
  (`ADS_VAT_PERCENT=0`). Every price we quote is net, so this is the figure the
  invoice will actually ask for.
  """
  def vat_display(cents \\ Ads.price_cents()) do
    if Ads.vat_percent() > 0 do
      gettext("plus %{percent} % VAT = %{gross} €",
        percent: Ads.vat_percent(),
        gross: UI.euro_cents(Ads.gross_cents(cents))
      )
    end
  end

  @doc """
  The sample ad the offer page shows, so a buyer sees the three lines they are
  buying rather than reading about them. Deliberately a plain `%Ad{}` and never
  a stored row: `example.com` is the reserved example domain, so the card can
  carry a working-looking address that belongs to nobody.
  """
  def sample_ad do
    %Ad{
      title: gettext("Acme is looking for you"),
      body: gettext("Elixir development in Mainz, remote is fine."),
      url: "https://www.example.com/jobs"
    }
  end

  @doc "The same sample as facts, for the agent formats."
  def example do
    ad = sample_ad()
    %{title: ad.title, text: ad.body, url: ad.url, address: Ad.display_url(ad.url)}
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
        vat_percent: Ads.vat_percent(),
        gross_cents: Ads.gross_cents(Ads.price_cents()),
        display: price_display(),
        vat_display: vat_display(),
        tiers:
          Enum.map(tier_lines(), fn line ->
            %{
              days: line.days,
              cents: line.cents,
              gross_cents: Ads.gross_cents(line.cents),
              display: line.price,
              saving: line.saving
            }
          end)
      },
      rules: rules(),
      example: example(),
      next_available_day: next_available_day,
      booking_window: %{from: Ads.first_bookable_day(), to: Ads.last_bookable_day()},
      booked_days: Enum.sort(Ads.booked_days(), Date),
      booking_url: AgentDocs.abs_url("/system/ads/new"),
      community_guidelines_url: AgentDocs.abs_url("/community")
    })
  end
end
