defmodule Vutuv.Repo.Migrations.AddFkIndexesOnUserTagsAndEndorsements do
  use Ecto.Migration

  # The only existing indexes on these tables lead with user_id
  # (unique (user_id, tag_id) on user_tags, unique (user_id, user_tag_id) on
  # user_tag_endorsements), so neither helps the hot paths that filter or join
  # on the *second* FK column on its own:
  #   - Tag.reccomended_users/related_for filter `where us.tag_id == ^tag.id`
  #     on every profile page with tags and every tag page.
  #   - Activity.endorsement_items joins user_tag_endorsements -> user_tags on
  #     user_tag_id for the notifications feed, and per-chip endorsement
  #     preloads load endorsements by user_tag_id.
  # Plain single-column B-tree indexes cover those. Data size is small, so no
  # concurrent build is needed.
  def change do
    create index(:user_tags, [:tag_id])
    create index(:user_tag_endorsements, [:user_tag_id])
  end
end
