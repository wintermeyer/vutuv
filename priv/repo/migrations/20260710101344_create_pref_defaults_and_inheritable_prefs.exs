defmodule Vutuv.Repo.Migrations.CreatePrefDefaultsAndInheritablePrefs do
  use Ecto.Migration

  # The Vutuv.Prefs system: member preferences resolve member value →
  # installation default → shipped default.
  #
  # 1. `pref_defaults` stores the admin-set installation defaults (only the
  #    overrides; a missing key means "the shipped default applies").
  # 2. The per-member pref columns on `users` become *inheritable*: nullable,
  #    with no DB default — NULL now means "inherit the installation default".
  #    Values equal to the shipped default are folded to NULL, because until
  #    now the columns' own DB defaults made "never touched" and "chose the
  #    default" indistinguishable; folding gives an admin's future default
  #    change its intended reach (everyone who never customized).
  #
  # N-1 compatibility (blue/green): no column changes type, so no prepared
  # statements are invalidated. The previous release already tolerates NULLs
  # in every one of these columns — Vutuv.Maps reads NULL flags as "all on,
  # Google first" (unchanged behaviour) and User.post_prefs/1 reads a NULL
  # line count as "no truncation", so during the switch window the old slot
  # renders posts unclamped/unhyphenated: cosmetic, and only until nginx
  # flips to the new release.
  def up do
    create table(:pref_defaults) do
      add(:key, :string, null: false)
      add(:value, :string, null: false)

      timestamps()
    end

    create(unique_index(:pref_defaults, [:key]))

    # DROP DEFAULT / DROP NOT NULL via execute (not `modify`), so the column
    # type is never restated and cached plans on the old release stay valid.
    execute("ALTER TABLE users ALTER COLUMN post_lines_desktop DROP DEFAULT")
    execute("ALTER TABLE users ALTER COLUMN post_lines_mobile DROP DEFAULT")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_desktop DROP DEFAULT")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_desktop DROP NOT NULL")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_mobile DROP DEFAULT")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_mobile DROP NOT NULL")
    execute(~s(ALTER TABLE users ALTER COLUMN "map_google?" DROP DEFAULT))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_google?" DROP NOT NULL))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_openstreetmap?" DROP DEFAULT))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_openstreetmap?" DROP NOT NULL))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_apple?" DROP DEFAULT))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_apple?" DROP NOT NULL))
    execute("ALTER TABLE users ALTER COLUMN default_map_service DROP DEFAULT")
    execute("ALTER TABLE users ALTER COLUMN default_map_service DROP NOT NULL")

    # Fold shipped-default values to NULL = inherit. This also folds the few
    # members who explicitly chose the default value since these settings
    # shipped — indistinguishable from untouched rows anyway, and their
    # effective values do not change.
    execute("UPDATE users SET post_lines_desktop = NULL WHERE post_lines_desktop = 6")
    execute("UPDATE users SET post_lines_mobile = NULL WHERE post_lines_mobile = 8")
    execute("UPDATE users SET post_hyphenate_desktop = NULL WHERE post_hyphenate_desktop = false")
    execute("UPDATE users SET post_hyphenate_mobile = NULL WHERE post_hyphenate_mobile = true")
    execute(~s(UPDATE users SET "map_google?" = NULL WHERE "map_google?" = true))
    execute(~s(UPDATE users SET "map_openstreetmap?" = NULL WHERE "map_openstreetmap?" = true))
    execute(~s(UPDATE users SET "map_apple?" = NULL WHERE "map_apple?" = true))
    execute("UPDATE users SET default_map_service = NULL WHERE default_map_service = 'google'")
  end

  def down do
    execute("UPDATE users SET post_lines_desktop = 6 WHERE post_lines_desktop IS NULL")
    execute("UPDATE users SET post_lines_mobile = 8 WHERE post_lines_mobile IS NULL")

    execute(
      "UPDATE users SET post_hyphenate_desktop = false WHERE post_hyphenate_desktop IS NULL"
    )

    execute("UPDATE users SET post_hyphenate_mobile = true WHERE post_hyphenate_mobile IS NULL")
    execute(~s(UPDATE users SET "map_google?" = true WHERE "map_google?" IS NULL))
    execute(~s(UPDATE users SET "map_openstreetmap?" = true WHERE "map_openstreetmap?" IS NULL))
    execute(~s(UPDATE users SET "map_apple?" = true WHERE "map_apple?" IS NULL))
    execute("UPDATE users SET default_map_service = 'google' WHERE default_map_service IS NULL")

    execute("ALTER TABLE users ALTER COLUMN post_lines_desktop SET DEFAULT 6")
    execute("ALTER TABLE users ALTER COLUMN post_lines_mobile SET DEFAULT 8")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_desktop SET DEFAULT false")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_desktop SET NOT NULL")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_mobile SET DEFAULT true")
    execute("ALTER TABLE users ALTER COLUMN post_hyphenate_mobile SET NOT NULL")
    execute(~s(ALTER TABLE users ALTER COLUMN "map_google?" SET DEFAULT true))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_google?" SET NOT NULL))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_openstreetmap?" SET DEFAULT true))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_openstreetmap?" SET NOT NULL))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_apple?" SET DEFAULT true))
    execute(~s(ALTER TABLE users ALTER COLUMN "map_apple?" SET NOT NULL))
    execute("ALTER TABLE users ALTER COLUMN default_map_service SET DEFAULT 'google'")
    execute("ALTER TABLE users ALTER COLUMN default_map_service SET NOT NULL")

    drop(table(:pref_defaults))
  end
end
