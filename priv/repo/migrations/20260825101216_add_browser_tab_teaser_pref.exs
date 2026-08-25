defmodule Vutuv.Repo.Migrations.AddBrowserTabTeaserPref do
  use Ecto.Migration

  @moduledoc """
  The browser tab's teaser (issue #1681): while a member's vutuv tab sits in the
  background, a new post pages its first line through the tab title instead of
  only putting a dot there. The sibling of the feed's tab ticker (#1668), one
  surface further out.

  One knob, `Vutuv.Prefs` group `:browser_tab`: `browser_tab_teaser?`. Nullable
  with **no** DB default, like every other pref column — NULL means "inherit the
  installation default", and the shipped value (on) lives only in the registry.

  N-1 safe: a pure nullable addition the deployed release never reads.
  """

  def change do
    alter table(:users) do
      add(:browser_tab_teaser?, :boolean)
    end
  end
end
