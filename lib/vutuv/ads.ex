defmodule Vutuv.Ads do
  @moduledoc """
  The daily text-ad system.

  Exactly one ad runs per calendar day (Europe/Berlin). Logged-in members
  book a future day online (`book_ad/2`): the day is reserved in the
  database and the billing data plus the ad text are mailed to the operator,
  who invoices manually. Every ad must be family-friendly and is **reviewed
  by an admin before it runs** (`approve_ad/2`, the dashboard at
  `/admin/ads`); to leave room for that review the earliest bookable day is
  three days out (`first_bookable_day/0`). Serving is automatic:
  `current_banner/0` is what `VutuvWeb.Plug.AdBanner` shows between the
  navigation and the content - the **approved** ad on its day, the house ad
  (an ad for the ad system) on days nobody booked (or where approval never
  came).

  Day boundaries are German local time, computed with the fixed EU DST rule
  (see `berlin_date/1`) because the project deliberately carries no timezone
  database dependency.
  """

  import Ecto.Query

  alias Vutuv.Ads.Ad
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo

  # The fixed price per day, in cents net (1250 EUR). Stamped onto every
  # booking so old rows keep the price that was agreed.
  @price_cents 125_000

  # Days between booking and the earliest bookable day: every ad is approved
  # by an admin before it runs, and this is the room for that review.
  @approval_lead_days 3

  # The booking window reaches to the end of next month, so the booking page
  # shows availability as two full month calendars and bookings stay
  # near-term. Widen by bumping this one knob (the calendar follows).
  @booking_window_months 1

  def price_cents, do: @price_cents

  @doc """
  Whether the daily text-ad system is switched on, from
  `config :vutuv, :ads_enabled` (default **off**). The single gate the rest
  of the app asks: when off, no banner serves (`VutuvWeb.Plug.AdBanner`), the
  public `/ads` flow and the admin review dashboard answer 404
  (`VutuvWeb.Plug.RequireAdsEnabled`), and nothing can be booked. `"ads"`
  stays a reserved slug regardless (see `Vutuv.Accounts.ReservedSlugs`), so
  the handle stays free for when the system is turned back on.
  """
  def enabled?, do: Application.get_env(:vutuv, :ads_enabled, false)

  @doc "The earliest day a new booking may pick (today + #{@approval_lead_days}, Berlin)."
  def first_bookable_day, do: Date.add(today(), @approval_lead_days)

  @doc """
  The last bookable day: the end of the month #{@booking_window_months} month(s)
  out - the last grid of the availability calendar on the booking page.
  """
  def last_bookable_day do
    today() |> Date.shift(month: @booking_window_months) |> Date.end_of_month()
  end

  @doc "Every taken day inside the booking window, as a MapSet (the calendar)."
  def booked_days do
    first = first_bookable_day()
    last = last_bookable_day()

    from(a in Ad, where: a.day >= ^first and a.day <= ^last, select: a.day)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "The ad booked for `day`, or nil."
  def get_ad(%Date{} = day), do: Repo.get_by(Ad, day: day)

  @doc """
  The ad with this id - booker and approving admin preloaded (the admin
  detail page) - or nil (also on a malformed id).
  """
  def get_ad_by_id(id) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Ad |> Repo.get(uuid) |> Repo.preload([:user, :approved_by])
    end
  end

  @doc """
  What the banner shows right now: `{:ad, ad}` on a booked day whose ad has
  been approved, `:house` (the ad for the ad system) otherwise. An
  unapproved ad never serves.
  """
  def current_banner do
    ad =
      Repo.one(from(a in Ad, where: a.day == ^today() and not is_nil(a.approved_at)))

    case ad do
      nil -> :house
      ad -> {:ad, ad}
    end
  end

  @doc """
  Books `attrs`'s day for `user` and mails the booking (billing data + ad
  text) to the operator. The unique index on `day` decides races; payment is
  by manually sent invoice, so nothing else happens here.
  """
  def book_ad(user, attrs) do
    %Ad{user_id: user.id, price_cents: @price_cents}
    |> Ad.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, ad} ->
        ad
        |> Emailer.ad_booking_email(user)
        |> Emailer.deliver()

        {:ok, ad}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Changeset for the booking form."
  def change_ad(%Ad{} = ad, attrs \\ %{}), do: Ad.changeset(ad, attrs)

  @doc """
  The check-before-buying step: validates `attrs` like `book_ad/2` would
  (including whether the day is still free, which `book_ad/2` only learns
  from the unique index) and returns the would-be ad without persisting
  anything - the preview page renders it through the real banner component.
  """
  def preview_ad(attrs) do
    %Ad{price_cents: @price_cents}
    |> Ad.changeset(attrs)
    |> validate_day_free()
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp validate_day_free(changeset) do
    Ecto.Changeset.validate_change(changeset, :day, fn :day, day ->
      if get_ad(day), do: [day: "has already been booked"], else: []
    end)
  end

  @doc """
  The admin review gate: stamps `approved_at` and the approving admin, after
  which the ad serves on its day. Idempotent - approving an already approved
  ad keeps the original stamp (so two admins clicking at once cannot
  reassign the approval).
  """
  def approve_ad(%Ad{approved_at: nil} = ad, admin) do
    ad
    |> Ecto.Changeset.change(
      approved_at: DateTime.truncate(DateTime.utc_now(), :second),
      approved_by_id: admin.id
    )
    |> Repo.update()
  end

  def approve_ad(%Ad{} = ad, _admin), do: {:ok, ad}

  @doc "All bookings of `user`, newest day first (the member dashboard)."
  def user_ads(user) do
    Repo.all(from(a in Ad, where: a.user_id == ^user.id, order_by: [desc: a.day]))
  end

  @doc """
  The admin dashboard lists: upcoming ads (today included) in serving order
  with their bookers preloaded, and the recent past for reference.
  """
  def upcoming_ads do
    Repo.all(from(a in Ad, where: a.day >= ^today(), order_by: [asc: a.day], preload: [:user]))
  end

  @doc "The most recent past ads (reference section of the admin dashboard)."
  def past_ads(limit \\ 50) do
    Repo.all(
      from(a in Ad,
        where: a.day < ^today(),
        order_by: [desc: a.day],
        limit: ^limit,
        preload: [:user]
      )
    )
  end

  @doc "How many upcoming ads still wait for approval (the admin panel badge)."
  def pending_ads_count do
    Repo.aggregate(
      from(a in Ad, where: a.day >= ^today() and is_nil(a.approved_at)),
      :count
    )
  end

  @doc """
  The first free day inside the booking window
  (`first_bookable_day/0`..`last_bookable_day/0`), nil when it is sold out.
  """
  def next_available_day do
    booked = booked_days()

    Enum.find(
      Date.range(first_bookable_day(), last_bookable_day()),
      &(not MapSet.member?(booked, &1))
    )
  end

  @doc "Today as a German calendar day (Europe/Berlin)."
  defdelegate today, to: Vutuv.BerlinTime

  @doc """
  The German calendar date of a UTC instant. The Berlin day rule lives in
  `Vutuv.BerlinTime` now (the ad rotation and the profile age display share
  it); kept here as a thin alias so existing callers keep working.
  """
  defdelegate berlin_date(utc), to: Vutuv.BerlinTime, as: :date
end
