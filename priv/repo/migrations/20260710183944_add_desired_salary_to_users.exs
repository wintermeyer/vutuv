defmodule Vutuv.Repo.Migrations.AddDesiredSalaryToUsers do
  use Ecto.Migration

  # The member's minimum salary expectation / Gehaltsvorstellung (issue #928,
  # the Jobs & Companies milestone). `desired_salary_min` is a whole-currency-
  # unit integer (nil = not stated): the codebase models money as integers
  # (ads `price_cents`) and never as `:decimal`, and the display goes through
  # the integer-only `delimited_count/1`, so an integer keeps the whole
  # pipeline (validation, profile line, JSON/XML) clean; a later need for
  # sub-unit precision is a trivial N-1 widen. Currency/period/visibility are
  # NOT NULL with defaults so the currently deployed release (which never
  # writes them) keeps inserting valid rows — a plain, N-1-compatible add.
  #
  # The value's real job is matching, not display: even at `hidden` visibility
  # it will prefill the job board's salary filter and let alerts skip postings
  # below the minimum (milestone issues 6/9 and 8/9). Visibility only governs
  # who *else* sees it, defaulting to `hidden`.
  def change do
    alter table(:users) do
      add :desired_salary_min, :integer
      add :desired_salary_currency, :string, null: false, default: "EUR"
      add :desired_salary_period, :string, null: false, default: "year"
      add :desired_salary_visibility, :string, null: false, default: "hidden"
    end
  end
end
