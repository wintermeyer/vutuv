defmodule Vutuv.Repo.Migrations.AddAccountToContentFilters do
  use Ecto.Migration

  # Which accounts a content filter applies to. `*` — the default, and what
  # every row written so far means — is "every account"; anything else narrows
  # the rule to the accounts whose handle or name it matches, with `*` as the
  # wildcard the pattern column already uses.
  #
  # A member following a news house gets the same story in a dozen spellings
  # from a dozen of its accounts (`@heiseonline@social.heise.de`,
  # `@heisec@…`, `@ct_Magazin@…`), so the rule that silences it has to be aimed
  # at the source rather than at the whole timeline.
  #
  # `NOT NULL DEFAULT '*'` is what backfills the existing rows — Postgres fills
  # them as it adds the column, without a rewrite — and the default is also what
  # keeps the **previous** release working through the blue/green window: its
  # INSERT does not name the column, and the row it writes still means what it
  # meant before.
  def change do
    alter table(:content_filters) do
      add(:account, :string, null: false, default: "*")
    end

    # The unique key gains the account: the same word may now be muted twice,
    # once per set of accounts, and only an identical scope is the duplicate the
    # index is there to refuse.
    #
    # It keeps the OLD index name on purpose. `unique_constraint` matches on the
    # name, so a fresh one would leave the release still serving traffic during
    # the migration unable to recognise its own duplicate — a member re-muting a
    # word would get an `Ecto.ConstraintError` 500 instead of "you already mute
    # this".
    drop(unique_index(:content_filters, [:user_id, :kind, :pattern]))

    create(
      unique_index(:content_filters, [:user_id, :kind, :pattern, :account],
        name: :content_filters_user_id_kind_pattern_index
      )
    )
  end
end
