defmodule Vutuv.Repo.Migrations.AddLanguageToPostDrafts do
  use Ecto.Migration

  @moduledoc """
  The language picked in the composer rides the draft (issue #1489), so a
  reload does not silently fall back to the UI locale and mislabel the post.
  N-1 safe: a pure nullable addition.
  """

  def change do
    alter table(:post_drafts) do
      add(:language, :string)
    end
  end
end
