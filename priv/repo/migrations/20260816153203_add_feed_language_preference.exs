defmodule Vutuv.Repo.Migrations.AddFeedLanguagePreference do
  use Ecto.Migration

  @moduledoc """
  The feed language preference (issue #1461, Mastodon's chosen-languages
  filter plus a translate mode): `feed_languages` is the member's "show
  these languages" list (NULL = all — the Prefs convention that "never
  touched" stays distinguishable), `feed_foreign_posts` says what happens to
  the rest (original / translate / hide; NULL = inherit the installation
  default, a `Vutuv.Prefs` knob). N-1 safe: pure nullable additions.
  """

  def change do
    alter table(:users) do
      add(:feed_foreign_posts, :string)
      add(:feed_languages, {:array, :string})
    end
  end
end
