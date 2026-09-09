defmodule VutuvWeb.PressKitController do
  @moduledoc """
  `/:slug/press` — the page that hands a journalist the files (issue #2086):
  every press photo whole, with its caption, credit, dimensions, file size and a
  download, and every logo variant with its vector and its PNG.

  **The one page under a member's slug that is not noindexed.** Every other
  section page (`/links`, `/phone_numbers`, …) goes through the router's
  `:user_pipe`, whose `Vutuv.Plug.NoIndex` keeps personal data out of search
  results — the right rule for a phone number and the exact opposite of what a
  press kit is for. So this action resolves the slug with the same three plugs
  the profile itself uses, carries the member's *own* opt-outs
  (`noindex?` / `noai?`) rather than a blanket refusal, is listed in the sitemap
  (`Vutuv.Sitemap.press_entries/1`) and publishes schema.org `ImageObject`
  markup with `license` and `acquireLicensePage` — what image search reads to
  mark a picture licensable, and the whole reason the page exists.

  Its agent-format siblings are `VutuvWeb.AgentDocs.PressKitDoc`, and they
  render the **anonymous** view: the HTML page shows the owner a picture the AI
  check has not released yet, the documents never do (`VutuvWeb.AgentDocs`).
  """

  use VutuvWeb, :controller

  alias Vutuv.PressKit
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.PressKitDoc
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.UserHelpers

  plug(VutuvWeb.Plug.UserResolveSlug)
  plug(VutuvWeb.Plug.EnsureActivated)
  plug(VutuvWeb.Plug.AgentExportOptOut)

  def index(conn, _params) do
    user = conn.assigns[:user]
    {noindex?, noai?} = PressKit.robots_axes(user)

    AgentDocs.respond(conn,
      html: fn conn ->
        conn
        |> ContentPolicy.put_robots_header(noindex?, noai?)
        |> render("index.html",
          shelves: PressKit.public_shelves(user, conn.assigns[:current_user]),
          page_title: UserHelpers.member_page_title(user, gettext("Press"))
        )
      end,
      # The released shelves, deliberately: a document that offers a file must
      # offer one that can be fetched, whoever asks.
      doc: fn -> PressKitDoc.build(user, PressKit.published_shelves(user)) end
    )
  end
end
