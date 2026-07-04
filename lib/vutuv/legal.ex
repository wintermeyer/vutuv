defmodule Vutuv.Legal do
  @moduledoc """
  The installation's legal pages (Impressum, Datenschutzerklärung,
  Nutzungsbedingungen).

  Their content is per-installation data, not code: German law requires every
  operator to state their own identity, so the bodies live in the `legal_pages`
  table (trusted Markdown, edited by admins at /admin/legal) instead of being
  hardcoded to vutuv.de's operator. `VutuvWeb.PageController` renders a neutral
  placeholder for a page the operator has not written yet.
  """

  import Ecto.Query

  alias Vutuv.Legal.LegalPage
  alias Vutuv.Repo

  @doc "The fixed set of legal page slugs every installation has."
  def slugs, do: LegalPage.slugs()

  @doc "The stored page for a slug, or nil while the operator has not written it."
  def get_page(slug) when is_binary(slug) do
    Repo.one(from(p in LegalPage, where: p.slug == ^slug))
  end

  @doc """
  Creates or updates the page for a slug.

  The row is keyed by slug (one row per page), so the first save inserts and
  every later save updates in place.
  """
  def upsert_page(slug, attrs) when is_binary(slug) do
    (get_page(slug) || %LegalPage{})
    |> LegalPage.changeset(slug, attrs)
    |> Repo.insert_or_update()
  end

  @doc "A changeset for the /admin/legal edit form."
  def change_page(%LegalPage{} = page, slug, attrs \\ %{}) do
    LegalPage.changeset(page, slug, attrs)
  end
end
