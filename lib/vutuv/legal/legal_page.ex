defmodule Vutuv.Legal.LegalPage do
  @moduledoc """
  One of the installation's legal pages (Impressum, Datenschutzerklärung,
  Nutzungsbedingungen), keyed by its fixed slug.

  The body is **trusted** Markdown (only admins reach the editor at
  /admin/legal), rendered by `VutuvWeb.DevDocMarkdown` like the other
  repo-equivalent trusted content. Every installation writes its own operator
  identity here; a missing row renders a neutral placeholder instead.
  """

  use VutuvWeb, :model

  @slugs ~w(impressum datenschutzerklaerung nutzungsbedingungen)
  @max_body 100_000

  schema "legal_pages" do
    field(:slug, :string)
    field(:body, :string)

    timestamps()
  end

  def slugs, do: @slugs

  @doc """
  The slug is forced (never user input — the routes and the admin editor name
  it), so it always lands in the changes and `validate_inclusion` sees it.
  """
  def changeset(%__MODULE__{} = page, slug, attrs) do
    page
    |> cast(attrs, [:body])
    |> force_change(:slug, slug)
    |> validate_inclusion(:slug, @slugs)
    |> validate_required([:slug, :body])
    |> validate_length(:body, max: @max_body)
    |> unique_constraint(:slug)
  end
end
