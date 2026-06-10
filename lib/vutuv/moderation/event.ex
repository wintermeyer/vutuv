defmodule Vutuv.Moderation.Event do
  @moduledoc """
  The per-case audit log: one row per thing that happened to a moderation
  case (report filed, content frozen, relationship severed/restored, owner
  self-service, escalation, ruling, strike). `actor_id` is the member who
  caused it (nil for system actions like the deadline sweeper); `detail`
  carries small action-specific facts (category, strike level, what was
  severed). Admins read this as the case timeline.
  """

  use VutuvWeb, :model

  schema "moderation_events" do
    belongs_to(:case, Vutuv.Moderation.Case)
    belongs_to(:actor, Vutuv.Accounts.User)
    field(:action, :string)
    field(:detail, :map, default: %{})

    timestamps(updated_at: false)
  end
end
