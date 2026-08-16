defmodule Vutuv.Repo.Migrations.AddLanguageToPostsAndRemoteContent do
  use Ecto.Migration

  @moduledoc """
  The post's language, declared by its author (issue #1489) or read from an
  incoming object's AS2 `contentMap` (issue #1488). Stored as a lowercase
  primary language subtag ("de", "en"); NULL means legacy/undeclared —
  always shown, never auto-translated, no `contentMap` outbound.

  N-1 safe: pure additions, nullable, no backfill by design.
  """

  def change do
    for table <- [:posts, :fediverse_posts, :fediverse_notes] do
      alter table(table) do
        add(:language, :string)
      end
    end
  end
end
