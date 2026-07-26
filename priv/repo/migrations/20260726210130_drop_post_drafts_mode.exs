defmodule Vutuv.Repo.Migrations.DropPostDraftsMode do
  use Ecto.Migration

  @moduledoc """
  The contract half of the composer-tab removal (PR #1172, v7.175.0).

  `mode` carried the retired Text/Fotos tab of the draft's composer. The
  expand/contract rule (one release of backward compatibility) is satisfied:
  v7.175.0 neither reads nor writes the column — the `PostDraft` schema lost
  the field there — so it keeps serving unchanged while this migration runs
  during the blue/green switch.

  `remove/3` with the full column definition keeps the migration reversible;
  a rollback restores the column exactly as `create_post_drafts` declared it.
  """

  def change do
    alter table(:post_drafts) do
      remove(:mode, :string, null: false, default: "text")
    end
  end
end
