defmodule Vutuv.Repo.Migrations.AddFeedSourceToUsers do
  use Ecto.Migration

  @moduledoc """
  The feed's remembered source tab (issue #1499): which of All / vutuv /
  Fediverse the member last chose on `/feed`. NULL is "All" — the tab a member
  who never touched the bar opens on, and the value a click on "All" writes
  back. Written only by `Vutuv.Posts.remember_feed_filter/2`, which is why the
  column carries no check constraint: the three names are a closed vocabulary
  there, not user input. N-1 safe: a pure nullable addition.
  """

  def change do
    alter table(:users) do
      add(:feed_source, :string)
    end
  end
end
