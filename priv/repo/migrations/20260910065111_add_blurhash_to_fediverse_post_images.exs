defmodule Vutuv.Repo.Migrations.AddBlurhashToFediversePostImages do
  use Ecto.Migration

  # The publishing server's own blurred stand-in for the picture (issue #1914):
  # ~30 characters of base83 that every Mastodon attachment carries, including
  # the three quarters of clips that send no cover at all. Those had nothing to
  # draw and rendered as a black box.
  #
  # A string column, because 9x9 components is 166 characters at the format's
  # ceiling and `Vutuv.Blurhash` refuses anything longer — well inside
  # varchar(255), so the `validate_length` on the changeset is what bounds it.
  # A plain nullable addition: N-1 compatible in one deploy.
  def change do
    alter table(:fediverse_post_images) do
      add(:blurhash, :string)
    end
  end
end
