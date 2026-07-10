defmodule Vutuv.Repo.Migrations.CreateViewerExclusions do
  use Ecto.Migration

  def change do
    # Per-member viewer-exclusion list (issue #938, "Ausschlussliste"): a
    # general "these viewers never see my visibility-gated info" list, wired
    # first only to the #928 job-search fields (employment status + salary
    # expectation). Each row names ONE excluded target: a member account
    # (excluded_user_id) or an email domain (domain). Companies (#929) can join
    # later as a third nullable target without a new table.
    #
    # Purely additive and N-1 backward compatible: the currently-deployed
    # release never touches this table; the job-search visibility gate keeps
    # working unchanged until the new release consults the list.
    create table(:viewer_exclusions) do
      # The owner of the list — the member who is hiding.
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # An excluded member account (e.g. your boss, a colleague). Nullable:
      # a domain row leaves it null. ON DELETE cascades the row away when the
      # excluded member is deleted.
      add(:excluded_user_id, references(:users, on_delete: :delete_all))
      # An excluded email domain (lowercase host, no scheme/path/@). Any
      # signed-in viewer whose confirmed email is at this domain is excluded.
      add(:domain, :string)

      # Rows are immutable (add / remove only), so no updated_at.
      timestamps(updated_at: false)
    end

    # List an owner's exclusions, and the domain-match lookup for a viewer.
    create(index(:viewer_exclusions, [:user_id]))

    # Dedupe: an owner can hold a given member or domain at most once. Partial
    # so the null target of the other kind never collides.
    create(
      unique_index(:viewer_exclusions, [:user_id, :excluded_user_id],
        where: "excluded_user_id IS NOT NULL",
        name: :viewer_exclusions_user_id_excluded_user_id_index
      )
    )

    create(
      unique_index(:viewer_exclusions, [:user_id, :domain],
        where: "domain IS NOT NULL",
        name: :viewer_exclusions_user_id_domain_index
      )
    )

    # Exactly one target per row: a member XOR a domain, never both, never
    # neither. The schema enforces the same rule; this is the last-resort DB
    # guard so a bad insert can't slip a meaningless row in.
    create(
      constraint(:viewer_exclusions, :viewer_exclusions_one_target,
        check: "(excluded_user_id IS NOT NULL) <> (domain IS NOT NULL)"
      )
    )
  end
end
