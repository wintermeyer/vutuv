defmodule VutuvWeb.CompanyController do
  @moduledoc """
  The two company pages behind the footer's "Company" group: `/system/investors`
  and `/system/media-kit`.

  **Both are English only, in every locale.** They address two audiences that
  read English as a matter of course (investors, and journalists writing about
  the software), and the alternative — a German translation nobody maintains —
  drifts out of date the first time a figure changes. The footer labels them in
  English so the change of language is visible before the click, and both pages
  mark their content `lang="en"` so a screen reader and a translation tool are
  told the truth even when the document around them says German.

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
  """
  def investors(conn, _params) do
    facts = InvestorsDoc.facts()

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "investors.html",
          page_title: "Investors",
          facts: facts,
          facts_contact: InvestorsDoc.contact_email(),
          contact_profile_url: InvestorsDoc.contact_profile_url(),
          press_contact_name: MediaKitDoc.press_contact_name()
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
