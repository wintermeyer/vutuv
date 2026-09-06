defmodule Vutuv.Repo.Migrations.AddScreenshotPageChecks do
  @moduledoc """
  The screenshot blocklist stops being hand-written: a vision model looks at
  each fresh capture and says whether it shows the page or a consent wall, an
  ad wall, a login wall or a bot check.

  Two additions, no changes to what exists (N-1 safe: the currently deployed
  release keeps reading `pattern` and `note` and never sees the rest).

  `screenshot_page_checks` is the memory that keeps this cheap and reviewable:
  one row per host with the verdict, what the model saw, and when. A host
  whose last verdict is `usable` and younger than the re-check age is not
  looked at again — 2,026 stored captures came from 374 hosts, more than half
  of them from a single one, so without that memory the model would answer the
  same question about tagesschau.de a thousand times.

  `screenshot_blocklist_entries` gains `source` and `evidence_file`, so an
  automatic entry can be told apart from one an admin wrote, and the admin can
  see the very picture that caused it. Existing rows are `manual`, which is
  what they are.
  """

  use Ecto.Migration

  def change do
    create table(:screenshot_page_checks) do
      # The registrable host as `Vutuv.ScreenshotBlocklist.parse/1` normalises
      # it (no scheme, no `www.`, no port), which is the unit an entry names.
      add(:host, :string, null: false)
      # "usable" | "blocked" | "unknown" (the check could not answer)
      add(:verdict, :string, null: false)
      # "ai" (a measurement, which expires) or "admin" (a person's decision
      # about their own installation, which does not — otherwise removing an
      # automatic entry would only postpone it by 90 days).
      add(:source, :string, null: false, default: "ai")
      # What was in the way: consent, ads, login, paywall, captcha, error,
      # blank, other - or "none" on a usable page.
      add(:obstruction, :string)
      add(:coverage_percent, :integer)
      # The model's own sentence; a text column because it is machine prose we
      # cap rather than validate.
      add(:reason, :text)
      # The page that was judged, kept so an admin can look at the same URL.
      # `:text` like every other URL column here - a link is not ours to bound.
      add(:checked_url, :text)
      # Which model answered: a different model (or a rewritten prompt) makes
      # every stored verdict a different measurement, and this is what lets a
      # later release invalidate them instead of trusting them.
      add(:model, :string)
      add(:checked_at, :utc_datetime, null: false)

      timestamps()
    end

    create(unique_index(:screenshot_page_checks, [:host]))

    alter table(:screenshot_blocklist_entries) do
      add(:source, :string, null: false, default: "manual")
      add(:evidence_file, :string)
    end
  end
end
