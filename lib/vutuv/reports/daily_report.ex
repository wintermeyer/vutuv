defmodule Vutuv.Reports.DailyReport do
  @moduledoc """
  A single day's basic activity tally: confirmed-by-PIN new registrations and
  how many posts, reposts, likes and bookmarks were created on one German
  calendar day (`Vutuv.BerlinTime`).

  Built by `Vutuv.Reports.daily/1`, rendered on the admin reports page
  (`VutuvWeb.Admin.ReportController`) and mailed each night by
  `Vutuv.Reports.DailyReporter`.
  """

  @enforce_keys [:date]
  defstruct [:date, registrations: 0, posts: 0, reposts: 0, likes: 0, bookmarks: 0]

  @type t :: %__MODULE__{
          date: Date.t(),
          registrations: non_neg_integer(),
          posts: non_neg_integer(),
          reposts: non_neg_integer(),
          likes: non_neg_integer(),
          bookmarks: non_neg_integer()
        }

  @doc "The five tallied metrics, summed."
  def total(%__MODULE__{} = report) do
    report.registrations + report.posts + report.reposts + report.likes + report.bookmarks
  end

  @doc """
  True when every metric is zero, a quiet day. The overnight email is skipped
  on such days (`Vutuv.Reports.deliver_daily_email/1`) so a dead-quiet night
  never mails an all-zeros report.
  """
  def all_zero?(%__MODULE__{} = report), do: total(report) == 0
end
