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
    # The page the content belongs to, where it belongs to one (issue #2120):
    # who *answers* for it stays `owner_id`, this says who else has to be
    # **told**. Set beside `owner_id` when the case is minted; never cast.
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:resolved_by, Vutuv.Accounts.User)
    has_many(:reports, Vutuv.Moderation.Report, foreign_key: :case_id)

    timestamps()
  end

  def open_statuses, do: @open_statuses

  @doc """
  What a reporter is told a closed case ended in: `"removed"`, `"revised"`,
  `"upheld"`, `"not_upheld"` — or nil while it is still open (issue #2011).

  It lives beside `@statuses` because it has to track that list: a status added
  above and not answered here falls into the nil clause and quietly tells nobody
  anything.

  The four are not the statuses renamed. `"upheld"` is deliberately *not*
  "removed", because an upheld case does not always remove anything: a picture
  is purged, a post stays frozen as evidence, and an upheld **profile** case
  unfreezes the profile and lands on the strike ladder instead — telling that
  reporter the content was removed would be false. So the notice says the report
  was upheld and stops there, which is true in all three.
  """
  def reporter_outcome("resolved_deleted"), do: "removed"
  def reporter_outcome("resolved_edited"), do: "revised"
  def reporter_outcome("upheld"), do: "upheld"
  def reporter_outcome("rejected"), do: "not_upheld"
  def reporter_outcome(_status), do: nil

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
