defmodule Vutuv.Moderation.Severance do
  @moduledoc """
  What `Vutuv.Moderation.report_content/3` separated between the reporter and
  the content owner at report time: the follow edges and the frozen 1:1
  conversation. One row per report with a standing relationship; `restored_at`
  is set when a rejected case put things back
  (`Vutuv.Moderation.reject_case/3`). An upheld case leaves the row unrestored -
  the separation sticks.

  A mutual follow (both `had_follow_*` true) is what restores the "vernetzt"
  connection, so there is no separate connection state to record any more.
  """

  use VutuvWeb, :model

  schema "moderation_severances" do
    belongs_to(:case, Vutuv.Moderation.Case)
    belongs_to(:reporter, Vutuv.Accounts.User)
    belongs_to(:owner, Vutuv.Accounts.User)

    field(:had_follow_reporter_to_owner?, :boolean, default: false)
    field(:had_follow_owner_to_reporter?, :boolean, default: false)
    belongs_to(:conversation, Vutuv.Chat.Conversation)
    field(:restored_at, :naive_datetime)

    timestamps()
  end
end
