defmodule Vutuv.Repo.Migrations.CreateLegalPages do
  use Ecto.Migration

  @moduledoc """
  Per-installation legal pages (Impressum, Datenschutzerklärung,
  Nutzungsbedingungen). The body is trusted Markdown, edited by admins at
  /admin/legal, so every installation states its own operator identity instead
  of the previously hardcoded vutuv.de templates. A page without a row renders
  a neutral placeholder. Plain addition, N-1 safe: the previous release keeps
  rendering its hardcoded templates and never touches this table.
  """

  def change do
    create table(:legal_pages) do
      add(:slug, :string, null: false)
      add(:body, :text, null: false)

      timestamps()
    end

    create(unique_index(:legal_pages, [:slug]))
  end
end
