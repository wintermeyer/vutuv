defmodule VutuvWeb.ApiV2.OrganizationController do
  @moduledoc """
  Verified organization pages over the API (issue #936, `jobs:read`) — read-only,
  the same doc the public `.json` pages serve (`VutuvWeb.AgentDocs.OrganizationDoc`),
  so HR tooling can resolve the employer behind a posting.

  `GET /organizations` lists verified organizations (paginated, `?q=` search);
  `GET /organizations/:slug` returns one page with its aliases, verified domains,
  postal address, linked people and open positions.
  """

  use VutuvWeb, :controller

  alias Vutuv.Organizations
  alias Vutuv.Pages
  alias VutuvWeb.AgentDocs.OrganizationDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  def index(conn, params) do
    page = Organizations.directory_page(page: Pages.page_param(params), search: params["q"])

    doc =
      page.entries
      |> OrganizationDoc.build_index(page.total)
      |> Map.merge(%{page: page.page, total_pages: page.total_pages})

    ApiV2.send_json(conn, doc)
  end

  # Resolve by slug or by a claimed root handle (issue #941): the public page is
  # reachable both ways (`/organizations/:slug` and `/:handle`), and the listing's
  # `url` points at the canonical path — a handle for a handle-holding
  # organization — so a consumer that parses the last URL segment must resolve
  # against either.
  def show(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    with {:error, :not_found} <- Organizations.fetch_visible_organization(slug, viewer),
         {:error, :not_found} <-
           Organizations.fetch_visible_organization_by_username(slug, viewer) do
      Problem.not_found(conn)
    else
      {:ok, organization} -> ApiV2.send_json(conn, OrganizationDoc.build_show(organization))
    end
  end
end
