defmodule VutuvWeb.PressKitController do
  @moduledoc """
  The page that hands a journalist the files — `/:slug/press` for a member
  (issue #2086) and `/organizations/:slug/press` for a page (issue #2087):
  every press photo whole, with its caption, credit, dimensions, file size and
  a download, and every logo variant with its vector and its PNG.

  **One action per owner kind, one page.** The two differ in nothing a reader
  sees: the shelves, the components and the template are `Vutuv.PressKit`'s and
  take an owner. What they cannot share is how the owner is resolved — a member
  comes out of the handle namespace through three plugs, a page out of
  `Vutuv.Organizations.fetch_visible_organization/2` — so that is all `index/2`
  and `organization/2` do differently.

  **The one page under a member's slug that is not noindexed.** Every other
  section page (`/links`, `/phone_numbers`, …) goes through the router's
  `:user_pipe`, whose `Vutuv.Plug.NoIndex` keeps personal data out of search
  results — the right rule for a phone number and the exact opposite of what a
  press kit is for. So this action resolves the slug with the same three plugs
  the profile itself uses, carries the owner's *own* opt-outs
  (`Vutuv.PressKit.robots_axes/1`, a member's `noindex?`/`noai?` and a page's
  `seo?`), is listed in the sitemap (`Vutuv.Sitemap`) and publishes schema.org
  `ImageObject` markup with `license` and `acquireLicensePage` — what image
  search reads to mark a picture licensable, and the whole reason the page
  exists.

  Its agent-format siblings are `VutuvWeb.AgentDocs.PressKitDoc`, and they
  render the **anonymous** view: the HTML page shows the owner a picture the AI
  check has not released yet, the documents never do (`VutuvWeb.AgentDocs`).
  """

  use VutuvWeb, :controller

  alias Vutuv.Organizations
  alias Vutuv.PressKit
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.PressKitDoc
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.PressKitHTML

  # The member action's own resolution. A page is resolved in `organization/2`
  # instead, so these three never see it.
  plug(VutuvWeb.Plug.UserResolveSlug when action == :index)
  plug(VutuvWeb.Plug.EnsureActivated when action == :index)
  plug(VutuvWeb.Plug.AgentExportOptOut when action == :index)

  def index(conn, _params) do
    user = conn.assigns[:user]

    AgentDocs.respond(conn,
      html: fn conn -> render_press(conn, user) end,
      # The released shelves, deliberately: a document that offers a file must
      # offer one that can be fetched, whoever asks.
      doc: fn -> PressKitDoc.build(user, PressKit.published_shelves(user)) end
    )
  end

  @doc """
  A page's press section (issue #2087). The page twin of `index/2`, and the same
  page: the shelves, the template and the documents take an owner.

  It negotiates by hand rather than through `AgentDocs.respond/2` because the
  agent formats answer a **second** question here. `fetch_visible_organization/2`
  hands an owner or an admin the page while it is still pending or frozen, which
  is right for the HTML they are looking at and wrong for a document that is
  cached publicly for five minutes — so the siblings ask
  `Organizations.agent_visible?/1`, exactly as the page's own `.md`/`.json` do.
  """
  def organization(conn, %{"slug" => slug}) do
    case Organizations.fetch_visible_organization(slug, conn.assigns[:current_user]) do
      {:error, :not_found} ->
        ControllerHelpers.render_error(conn, 404)

      {:ok, organization} ->
        case AgentDocs.negotiate(conn) do
          :html ->
            conn
            |> AgentDocs.put_html_alternates()
            |> render_press(organization)

          format ->
            send_organization_doc(conn, format, organization)
        end
    end
  end

  defp send_organization_doc(conn, format, organization) do
    if Organizations.agent_visible?(organization) do
      AgentDocs.send_doc(
        conn,
        format,
        PressKitDoc.build(organization, PressKit.published_shelves(organization))
      )
    else
      ControllerHelpers.render_error(conn, 404)
    end
  end

  defp render_press(conn, owner) do
    {noindex?, noai?} = PressKit.robots_axes(owner)

    conn
    |> ContentPolicy.put_robots_header(noindex?, noai?)
    |> render("index.html",
      owner: owner,
      shelves: PressKit.public_shelves(owner, conn.assigns[:current_user]),
      page_title: PressKitHTML.press_page_title(owner)
    )
  end
end
