defmodule Vutuv.Repo.Migrations.AddPostDisplayPrefsToUsers do
  use Ecto.Migration

  # Per-reader post-display preferences, applied to every post this member reads
  # (feed, profile Beiträge, permalink). The line counts drive the CSS clamp on
  # the preview body — desktop and mobile separately, defaulting to 6 and 8 —
  # and are nullable because a NULL (or 0) means "no truncation at all". The
  # hyphenation booleans drive `hyphens:` on the post body; the defaults
  # reproduce the previous blanket behaviour (off on desktop, on for the narrow
  # phone column). Plain additive columns, so N-1 compatible in one deploy.
  def change do
    alter table(:users) do
      add :post_lines_desktop, :integer, default: 6
      add :post_lines_mobile, :integer, default: 8
      add :post_hyphenate_desktop, :boolean, default: false, null: false
      add :post_hyphenate_mobile, :boolean, default: true, null: false
    end
  end
end
