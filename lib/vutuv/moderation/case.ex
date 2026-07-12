defmodule Vutuv.Moderation.Case do
  @moduledoc """
  One moderation case per reported piece of content. Reports from individual
  users merge into the open case; the case carries the lifecycle.

  Statuses:

    * `"pending_owner"` — content frozen, owner has 72h to delete, edit or
      dispute before the case escalates to the admin queue.
    * `"flagged"` — in the admin queue without a freeze (low-trust reporter,
      or the first report against a whole profile).
    * `"escalated"` — in the admin queue (dispute, deadline passed, re-report
      after a self-service edit, or second reporter on a profile).
    * `"resolved_deleted"` / `"resolved_edited"` — owner fixed it; closed
      without admin involvement.
    * `"upheld"` — admin confirmed the violation (owner got a strike).
    * `"rejected"` — admin dismissed the report (content unfrozen).
  """

  use VutuvWeb, :model

  @open_statuses ~w(pending_owner flagged escalated)
  @statuses @open_statuses ++ ~w(resolved_deleted resolved_edited upheld rejected)

  schema "moderation_cases" do
    field(:content_type, :string)
    field(:content_id, Vutuv.UUIDv7)
    field(:status, :string)
    field(:owner_deadline_at, :naive_datetime)
    field(:escalated_at, :naive_datetime)
    field(:resolved_at, :naive_datetime)
    field(:content_snapshot, :string)
    # Set by Vutuv.Moderation.EvidenceScreenshot after the async capture at
    # report time; never cast.
    field(:evidence_screenshot, :string)

    belongs_to(:owner, Vutuv.Accounts.User)
    belongs_to(:resolved_by, Vutuv.Accounts.User)
    has_many(:reports, Vutuv.Moderation.Report, foreign_key: :case_id)

    timestamps()
  end

  def open_statuses, do: @open_statuses

  def changeset(case_record, params \\ %{}) do
    case_record
    |> cast(params, [
      :status,
      :owner_deadline_at,
      :escalated_at,
      :resolved_at,
      :content_snapshot
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    # The partial unique index (content_type, content_id) WHERE status is open:
    # lets a concurrent first-report on the same content lose gracefully (join
    # the now-open case) instead of raising Ecto.ConstraintError -> a 500.
    |> unique_constraint([:content_type, :content_id],
      name: :moderation_cases_open_content_index,
      message: "already has an open case"
    )
  end
end
