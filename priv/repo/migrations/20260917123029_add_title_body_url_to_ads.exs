defmodule Vutuv.Repo.Migrations.AddTitleBodyUrlToAds do
  use Ecto.Migration

  # An ad becomes a title, a sentence and one link, in the style of classic
  # text ads, instead of free Markdown. Plain additions plus a dropped NOT NULL,
  # so this is N-1 compatible in one deploy: the running release keeps writing
  # `content`, and a row without it only reaches that release as an empty
  # Markdown body. `content` stays as it is (no type change, so no invalidated
  # prepared statements) and goes in a later deploy, which also makes the three
  # new columns NOT NULL and drops the stopgap for an old-format ad (it has no
  # title and never serves, `Vutuv.Ads`). Rolling this back fails once an ad of
  # the new format exists, since those rows have no `content` to satisfy the
  # restored NOT NULL.
  def change do
    alter table(:ads) do
      # Capped at 30 and 90 characters by the changeset.
      add(:title, :string)
      add(:body, :string)
      # Where the title leads, up to 2048 characters (`Vutuv.Ads.Ad`).
      add(:url, :text)
    end

    execute(
      "ALTER TABLE ads ALTER COLUMN content DROP NOT NULL",
      "ALTER TABLE ads ALTER COLUMN content SET NOT NULL"
    )
  end
end
