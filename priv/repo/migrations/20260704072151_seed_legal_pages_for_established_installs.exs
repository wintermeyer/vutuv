defmodule Vutuv.Repo.Migrations.SeedLegalPagesForEstablishedInstalls do
  use Ecto.Migration

  @moduledoc """
  Seeds the three legal pages with the vutuv.de content that was hardcoded in
  the templates until now — but **only on an established installation** (one
  that already has users when this migration runs, i.e. vutuv.de production and
  its dev copies). A **fresh** third-party installation has an empty users
  table at migration time and gets no rows, so it renders the neutral
  placeholder instead of Wintermeyer Consulting's Impressum until its operator
  fills in their own pages at /admin/legal.

  The content comes from priv/repo/seed_data/legal/*.md — the frozen snapshot
  of the vutuv.de legal texts at the time this migration shipped. After this
  ran, the DB rows (edited at /admin/legal) are the live truth, not the files.
  """

  @slugs ~w(impressum datenschutzerklaerung nutzungsbedingungen)

  def up do
    %{rows: [[established?]]} =
      repo().query!("SELECT EXISTS(SELECT 1 FROM users LIMIT 1)")

    if established? do
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      for slug <- @slugs do
        body =
          :vutuv
          |> Application.app_dir("priv/repo/seed_data/legal/#{slug}.md")
          |> File.read!()

        repo().query!(
          """
          INSERT INTO legal_pages (id, slug, body, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $4)
          ON CONFLICT (slug) DO NOTHING
          """,
          [Ecto.UUID.dump!(Vutuv.UUIDv7.generate()), slug, body, now]
        )
      end
    end
  end

  def down do
    repo().query!("DELETE FROM legal_pages WHERE slug = ANY($1)", [@slugs])
  end
end
