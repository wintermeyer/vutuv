defmodule Vutuv.Activity.NotificationVisit do
  @moduledoc """
  One look at the notifications: the member opened /notifications
  (`source: "page"`) or closed the bell's preview (`"bell"`). The page draws
  each one as a line in its timeline and can show the list as it stood then
  (`Vutuv.Activity.record_notification_visit/2` has the rules).
  """

  use VutuvWeb, :model

  @sources ~w(page bell)

  schema "notification_visits" do
    field(:at, :utc_datetime)
    field(:source, :string)

    belongs_to(:user, Vutuv.Accounts.User)
  end

  @doc "The places a look can come from."
  def sources, do: @sources
end
