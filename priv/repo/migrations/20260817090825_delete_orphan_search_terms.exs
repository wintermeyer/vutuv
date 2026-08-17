defmodule Vutuv.Repo.Migrations.DeleteOrphanSearchTerms do
  use Ecto.Migration

  @moduledoc """
  Drops the `search_terms` rows that belong to nobody.

  `search_terms` is the people-search name index: `SearchTerm.create_search_terms/1`
  writes eighteen rows per member, derived from their first and last name. In
  December 2016 two migrations (`add_skills_search_fields`,
  `update_skill_search_terms`) also filled it with the *skills* of the day —
  "elixir", "ruby on rails", "dba" — which carried no `user_id`. Skills became
  tags years ago and nothing has written such a row since; they are 5,964 of the
  113,010 rows on production.

  They were never merely idle. Both member-facing search paths inner-join
  `users`, so an orphan can never surface — but the history matcher left-joined,
  which is how `search_query_results` collected rows pointing at no member.

  Irreversible on purpose: the rows describe a feature that no longer exists, so
  there is nothing to restore them to.
  """

  def up do
    execute("DELETE FROM search_terms WHERE user_id IS NULL")
  end

  def down do
    :ok
  end
end
