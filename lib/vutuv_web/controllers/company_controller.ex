defmodule VutuvWeb.CompanyController do
  @moduledoc """
  The two company pages behind the footer's "Company" group: `/system/investors`
  and `/system/media-kit`.

  **The media kit is English only, in every locale.** It addresses journalists
  writing about the software, who read English as a matter of course, and it is
  mostly boilerplate that a second unmaintained copy would drift away from the
  first time a sentence changes. The footer labels it in English so the change
  of language is visible before the click, and the page marks its content
  `lang="en"` so a screen reader and a translation tool are told the truth even
  when the document around it says German.

  **The investor page follows the reader's language** (German and English; a
  locale with no catalogue entries falls back to the English msgid, like every
  other page here). It was English only for the same reason, and that reasoning
  was wrong for this one: vutuv is a German site raising money in a German
  market, so its most likely reader is a German one, and a page arguing why to
  put six figures into something is the last place to make somebody read a
  second language. The drift argument is answered rather than accepted, by
  keeping every sentence of the argument in `InvestorsDoc` — one chokepoint the
  HTML and all four agent formats render.

  Under `/system/` rather than `/investors` and `/media-kit` because profiles own
  the URL root: a new root word is a handle no member could ever claim again.

  Both are served to third-party installations too, without a switch. A media kit
  is about the software's brand, which every installation runs; and while the
  investor page speaks for whoever operates an installation, every name and
  figure on it is read from that installation's own operator identity and its own
  live counts, so it says something true wherever it runs.
  """
  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.InvestorsDoc
  alias VutuvWeb.AgentDocs.MediaKitDoc

  @doc """
  The investor page. Every figure on it is read live rather than typed into the
  template, so the page cannot quietly go stale — see `InvestorsDoc.facts/0`,
  which this page and its agent-format siblings both render.

  It states no email address: an investor writes through vutuv itself
  (`InvestorsDoc.contact_handle/0`), which keeps a personal address off a page
  built to be read by strangers and machines, and spends the first minute of
  the conversation inside the product it is about. The operator's profile here
  is linked beside that.
  """
  def investors(conn, _params) do
    facts = InvestorsDoc.facts()

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "investors.html",
          page_title: gettext("Investors"),
          facts: facts,
          growth_sentence: InvestorsDoc.growth_sentence(facts.growth),
          contact_handle: InvestorsDoc.contact_handle(),
          contact_profile_url: InvestorsDoc.contact_profile_url()
        )
      end,
      doc: fn -> InvestorsDoc.build(facts) end
    )
  end

  @doc "The media kit: boilerplate, facts, brand assets, screenshots, contact."
  def media_kit(conn, _params) do
    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "media_kit.html",
          page_title: "Media Kit",
          boilerplate: MediaKitDoc.boilerplate(),
          facts: MediaKitDoc.facts(),
          assets: MediaKitDoc.assets(),
          colors: MediaKitDoc.colors(),
          typography: MediaKitDoc.typography(),
          screenshots: MediaKitDoc.screenshots(),
          usage: MediaKitDoc.usage_rules(),
          press_contact: MediaKitDoc.press_contact(),
          press_contact_name: MediaKitDoc.press_contact_name(),
          press_contact_profile_url: MediaKitDoc.press_contact_profile_url(),
          operator_name: Application.fetch_env!(:vutuv, :operator_name)
        )
      end,
      doc: fn -> MediaKitDoc.build() end
    )
  end
end
