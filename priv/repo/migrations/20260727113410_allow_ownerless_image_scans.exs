defmodule Vutuv.Repo.Migrations.AllowOwnerlessImageScans do
  use Ecto.Migration

  # Every image the AI gate had ever seen belonged to a member, so the job row
  # demanded one. Pictures fetched from another network (issue #1163) are the
  # first that belong to nobody here: the account that published them never
  # signed up, and there is no member whose content a rejection removes — which
  # is also why those two kinds are absent from the gate's notify list.
  #
  # Dropping a NOT NULL is N-1 safe on its own: the release still serving never
  # writes a null, so nothing it does becomes invalid.
  def up do
    execute("ALTER TABLE image_scans ALTER COLUMN owner_user_id DROP NOT NULL")
  end

  def down do
    # Only reversible once the ownerless rows are gone, which is what the
    # delete is for — they are queue/audit rows, not member content.
    execute("DELETE FROM image_scans WHERE owner_user_id IS NULL")
    execute("ALTER TABLE image_scans ALTER COLUMN owner_user_id SET NOT NULL")
  end
end
