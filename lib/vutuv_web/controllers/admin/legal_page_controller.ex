defmodule VutuvWeb.Admin.LegalPageController do
  @moduledoc """
  The editor for the installation's legal pages (Impressum,
  Datenschutzerklärung, Nutzungsbedingungen).

  Every installation must state its own operator identity on these pages, so
  their bodies are data (`Vutuv.Legal`, trusted Markdown), not code. The set of
  pages is fixed: this controller only edits the three known slugs, it never
  creates new page types.
  """

  use VutuvWeb, :controller

  alias Vutuv.Legal
  alias Vutuv.Legal.LegalPage
  alias VutuvWeb.Admin.LegalPageHTML
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    pages = Map.new(Legal.slugs(), &{&1, Legal.get_page(&1)})

    render(conn, "index.html", pages: pages, page_title: gettext("Legal pages"))
  end

  def edit(conn, %{"slug" => slug}) do
    with_slug(conn, slug, fn ->
      page = Legal.get_page(slug) || %LegalPage{slug: slug}

      render_edit(conn, slug, Legal.change_page(page, slug))
    end)
  end

  def update(conn, %{"slug" => slug, "legal_page" => params}) do
    with_slug(conn, slug, fn ->
      case Legal.upsert_page(slug, params) do
        {:ok, _page} ->
          conn
          |> put_flash(:info, gettext("The page has been published."))
          |> redirect(to: ~p"/admin/legal")

        {:error, changeset} ->
          render_edit(conn, slug, changeset)
      end
    end)
  end

  defp render_edit(conn, slug, changeset) do
    render(conn, "edit.html",
      slug: slug,
      changeset: changeset,
      page_title: LegalPageHTML.page_name(slug)
    )
  end

  defp with_slug(conn, slug, fun) do
    if slug in Legal.slugs() do
      fun.()
    else
      ControllerHelpers.render_error(conn, 404)
    end
  end
end
