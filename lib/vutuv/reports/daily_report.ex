defmodule Vutuv.Reports.DailyReport do
  @moduledoc """
  A single day's tally for the operator: confirmed-by-PIN new registrations,
  how many posts, reposts, likes and bookmarks were created, how many new
  Fediverse followers were gained, the day's email-deliverability events
  (hard bounces, address deactivations, account freezes and thaws) and the
  accounts an admin removed as spam from a moderation case, on one German
  calendar day (`Vutuv.BerlinTime`).

  Every metric also carries a capped `details` sample (`detail_limit/0` rows,
  oldest first) so the report can name *who* and *what*, not just how many:
  the new members, the created posts, the reposters/likers/bookmarkers, the
  new Fediverse followers, the bounced/deactivated/frozen/thawed addresses and
  the removed spam accounts. `Vutuv.Reports.daily/1` fills the sample;
  `VutuvWeb.ReportDetails.sections/1` turns it into linked lines for the email
  and the admin page.

  Built by `Vutuv.Reports.daily/1`, rendered on the admin reports page
  (`VutuvWeb.Admin.ReportController`) and mailed each night by
  `Vutuv.Reports.DailyReporter`.
  """

  # How many sample rows each metric carries in `details`. The email lists up
  # to this many entries per metric and notes "… und N weitere" beyond it, so
  # a busy day stays a readable overview rather than a wall of every like.
  @detail_limit 25

  @enforce_keys [:date]
  defstruct [
    :date,
    registrations: 0,
    posts: 0,
    reposts: 0,
    likes: 0,
    bookmarks: 0,
    fediverse_followers: 0,
    bounces: 0,
    deactivations: 0,
    freezes: 0,
    thaws: 0,
    spam_removals: 0,
    # Per-metric sample lists keyed by the metric atom (see the moduledoc); the
    # element shape varies by metric and is normalized in `VutuvWeb.ReportDetails`.
    details: %{}
  ]

  @type t :: %__MODULE__{
          date: Date.t(),
          registrations: non_neg_integer(),
          posts: non_neg_integer(),
          reposts: non_neg_integer(),
          likes: non_neg_integer(),
          bookmarks: non_neg_integer(),
          fediverse_followers: non_neg_integer(),
          bounces: non_neg_integer(),
          deactivations: non_neg_integer(),
          freezes: non_neg_integer(),
          thaws: non_neg_integer(),
          spam_removals: non_neg_integer(),
          details: %{optional(atom()) => list()}
        }

  @doc "How many sample rows each metric's `details` list holds at most."
  def detail_limit, do: @detail_limit

  # Each metric with its German singular/plural label, in subject order. The
  # report email is German-only, so the labels live here rather than in gettext.
  # This list also drives total/1 and all_zero?/1, so a new metric is added in
  # exactly one place.
  @metrics [
    {:registrations, "Registrierung", "Registrierungen"},
    {:posts, "Beitrag", "Beiträge"},
    {:reposts, "Repost", "Reposts"},
    {:likes, "Like", "Likes"},
    {:bookmarks, "Lesezeichen", "Lesezeichen"},
    {:fediverse_followers, "neuer Fediverse-Follower", "neue Fediverse-Follower"},
    {:bounces, "Bounce", "Bounces"},
    {:deactivations, "deaktivierte Adresse", "deaktivierte Adressen"},
    {:freezes, "eingefrorenes Konto", "eingefrorene Konten"},
    {:thaws, "aufgetautes Konto", "aufgetaute Konten"},
    {:spam_removals, "als Spam entferntes Konto", "als Spam entfernte Konten"}
  ]

  @doc "Every tallied metric, summed."
  def total(%__MODULE__{} = report) do
    @metrics |> Enum.map(fn {key, _, _} -> Map.fetch!(report, key) end) |> Enum.sum()
  end

  @doc """
  True when every metric is zero, a quiet day. The overnight email is skipped
  on such days (`Vutuv.Reports.deliver_daily_email/1`) so a dead-quiet night
  never mails an all-zeros report.
  """
  def all_zero?(%__MODULE__{} = report), do: total(report) == 0

  @doc """
  The German email subject: the date followed by a comma-separated summary of
  only the metrics that are non-zero, so the operator reads the numbers that
  actually matter that day (the zero ones are left out). Falls back to the bare
  "Tagesbericht <date>" if nothing happened (that day is never mailed anyway).
  """
  def email_subject(%__MODULE__{} = report) do
    date = Calendar.strftime(report.date, "%d.%m.%Y")

    case summary_parts(report) do
      [] -> "vutuv Tagesbericht #{date}"
      parts -> "vutuv Tagesbericht #{date}: #{Enum.join(parts, ", ")}"
    end
  end

  defp summary_parts(report) do
    for {key, singular, plural} <- @metrics,
        count = Map.fetch!(report, key),
        count > 0,
        do: "#{count} #{if count == 1, do: singular, else: plural}"
  end
end
