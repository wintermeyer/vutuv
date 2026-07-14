defmodule Vutuv.Repo.Migrations.CreateJobExclusions do
  use Ecto.Migration

  def change do
    # Per-posting (and per-organization) job-offer exclusion list (issue #939),
    # the poster-side twin of the #938 member exclusion list. Each row subtracts
    # ONE viewer group from ONE subject, as the last step of the posting's
    # visibility gate (subtracting never adds).
    #
    #   * subject — exactly one of `job_posting_id` (a single posting's own list)
    #     or `organization_id` (a verified organization's STANDING default,
    #     inherited by every posting attributed to it).
    #   * target dimension — exactly one of `excluded_user_id` (a member),
    #     `excluded_organization_id` (an organization: its verified domains, its
    #     role holders, and members whose current work experience links to it) or
    #     `domain` (an email domain + subdomains).
    #
    # Purely additive and N-1 backward compatible: the currently-deployed release
    # never touches this table; the job visibility gate keeps working unchanged
    # until the new release consults the list. All FKs cascade so a row disappears
    # with its subject (posting/organization) OR its target (member/organization),
    # which is the whole deletion-cleanup story for issue #939.
    create table(:job_exclusions) do
      # Subject: whose list this row is on. A posting's own list, or an
      # organization's standing default. Exactly one is set (check below).
      add(:job_posting_id, references(:job_postings, on_delete: :delete_all))
      add(:organization_id, references(:organizations, on_delete: :delete_all))

      # Target dimension: exactly one is set (check below).
      add(:excluded_user_id, references(:users, on_delete: :delete_all))
      add(:excluded_organization_id, references(:organizations, on_delete: :delete_all))
      add(:domain, :string)

      # Rows are immutable (add / remove only), so no updated_at.
      timestamps(updated_at: false)
    end

    # List a subject's rows, and cascade lookups.
    create(index(:job_exclusions, [:job_posting_id]))
    create(index(:job_exclusions, [:organization_id]))
    create(index(:job_exclusions, [:excluded_user_id]))
    create(index(:job_exclusions, [:excluded_organization_id]))

    # Dedupe per (subject, target). Six partial unique indexes, one per
    # subject×dimension: each names BOTH columns non-null in its WHERE so
    # Postgres' NULLS-DISTINCT rule never lets a duplicate slip through a NULL.
    create(
      unique_index(:job_exclusions, [:job_posting_id, :excluded_user_id],
        where: "job_posting_id IS NOT NULL AND excluded_user_id IS NOT NULL",
        name: :job_exclusions_posting_member
      )
    )

    create(
      unique_index(:job_exclusions, [:job_posting_id, :excluded_organization_id],
        where: "job_posting_id IS NOT NULL AND excluded_organization_id IS NOT NULL",
        name: :job_exclusions_posting_org
      )
    )

    create(
      unique_index(:job_exclusions, [:job_posting_id, :domain],
        where: "job_posting_id IS NOT NULL AND domain IS NOT NULL",
        name: :job_exclusions_posting_domain
      )
    )

    create(
      unique_index(:job_exclusions, [:organization_id, :excluded_user_id],
        where: "organization_id IS NOT NULL AND excluded_user_id IS NOT NULL",
        name: :job_exclusions_org_member
      )
    )

    create(
      unique_index(:job_exclusions, [:organization_id, :excluded_organization_id],
        where: "organization_id IS NOT NULL AND excluded_organization_id IS NOT NULL",
        name: :job_exclusions_org_org
      )
    )

    create(
      unique_index(:job_exclusions, [:organization_id, :domain],
        where: "organization_id IS NOT NULL AND domain IS NOT NULL",
        name: :job_exclusions_org_domain
      )
    )

    # Exactly one subject per row: a posting XOR an organization default.
    create(
      constraint(:job_exclusions, :job_exclusions_one_subject,
        check: "(job_posting_id IS NOT NULL) <> (organization_id IS NOT NULL)"
      )
    )

    # Exactly one target dimension per row: member XOR organization XOR domain.
    create(
      constraint(:job_exclusions, :job_exclusions_one_target,
        check:
          "(excluded_user_id IS NOT NULL)::int + (excluded_organization_id IS NOT NULL)::int + (domain IS NOT NULL)::int = 1"
      )
    )
  end
end
