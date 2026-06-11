defmodule VutuvWeb.AgentDocs.AdsDoc do
  @moduledoc """
  The `/ads` offer page (the daily text ad, see `Vutuv.Ads`) as a data map
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
      gettext("Shown to every visitor, between the top navigation and the page content."),
      gettext("Appears at most once per hour per visitor and hides itself after two minutes."),
      gettext("Text only: Markdown, up to %{max} characters, always clearly labeled as an ad.",
        max: Ad.content_max_length()
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

  @doc "The /ads page as a doc map."
  def build(next_available_day) do
    AgentDocs.doc_meta("advertising", "/ads")
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
      booking_url: AgentDocs.abs_url("/ads/new")
    })
  end
end
