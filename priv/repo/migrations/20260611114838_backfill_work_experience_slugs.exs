defmodule Vutuv.Repo.Migrations.BackfillWorkExperienceSlugs do
  use Ecto.Migration

  @moduledoc """
  Imported work experiences can carry a NULL (or empty) slug. Phoenix.Param
  falls back to the id for those since the same change in the app code, but
  pretty URLs are better, so give them a real slug where one can be built
  from title + organization. Rows whose text slugifies to nothing keep NULL
  (their URLs stay id-based).

  Data-only and idempotent, so it is N-1 safe: the running release ignores
  the new slug values until it links to them.
  """

  def up do
    # Same shape Vutuv.SlugHelpers.gen_slug/1 produces: lowercase, German
    # transliteration, non-word characters dropped, whitespace to dashes.
    # A duplicate within the backfill (or against an existing slug) gets a
    # short id-derived suffix, mirroring the short-sha collision strategy.
    execute """
    WITH candidates AS (
      SELECT id,
             trim(both '-' from
               regexp_replace(
                 regexp_replace(
                   translate(
                     replace(replace(replace(replace(
                       lower(coalesce(title, '') || ' ' || coalesce(organization, '')),
                       'ä', 'ae'), 'ö', 'oe'), 'ü', 'ue'), 'ß', 'ss'),
                     'áàâãåéèêëíìîïóòôõúùûçñýÿ',
                     'aaaaaeeeeiiiioooouuucnyy'
                   ),
                   '[^a-z0-9\\s-]', '', 'g'
                 ),
                 '[\\s_]+', '-', 'g'
               )
             ) AS base
      FROM work_experiences
      WHERE slug IS NULL OR slug = ''
    ),
    unique_slugs AS (
      SELECT c.id,
             CASE
               WHEN c.base = '' THEN NULL
               WHEN EXISTS (SELECT 1 FROM work_experiences w
                            WHERE w.slug = c.base AND w.id <> c.id)
                    OR COUNT(*) OVER (PARTITION BY c.base) > 1
               THEN c.base || '.' || substr(md5(c.id::text), 1, 8)
               ELSE c.base
             END AS new_slug
      FROM candidates c
    )
    UPDATE work_experiences w
    SET slug = u.new_slug
    FROM unique_slugs u
    WHERE w.id = u.id AND u.new_slug IS NOT NULL
    """
  end

  def down do
    :ok
  end
end
