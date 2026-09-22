defmodule VutuvWeb.AdHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad
  alias VutuvWeb.AgentDocs.AdsDoc
  alias VutuvWeb.UI

  embed_templates("../templates/ad/*")

  @doc """
  The availability calendar of the booking wizard: one grid per month of the
  booking window (`Vutuv.Ads.first_bookable_day/0` to `last_bookable_day/0`,
  this month and the next three), Monday-first, each day tagged `:free`,
  `:booked` or `:unavailable` (outside the window). `VutuvWeb.AdBookingLive`
  decides which free days may START the chosen block; this only says what is
  taken.
  """
  def calendar_months do
    today = Ads.today()
    first = Ads.first_bookable_day()
    last = Ads.last_bookable_day()
    booked = Ads.booked_days()

    # One grid per month the window touches, however wide the context says
    # the window is (today's month through last_bookable_day's month).
    month_span = last.year * 12 + last.month - (today.year * 12 + today.month)

    for offset <- 0..month_span do
      month_start = today |> Date.shift(month: offset) |> Date.beginning_of_month()

      %{
        title: "#{month_name(month_start.month)} #{month_start.year}",
        weeks: month_weeks(month_start, first, last, booked)
      }
    end
  end

  # Monday-aligned weeks of the month, nil-padded at both ends.
  defp month_weeks(month_start, first, last, booked) do
    lead = Date.day_of_week(month_start) - 1

    days =
      for day <- Date.range(month_start, Date.end_of_month(month_start)) do
        {day, day_state(day, first, last, booked)}
      end

    Enum.chunk_every(List.duplicate(nil, lead) ++ days, 7, 7, List.duplicate(nil, 6))
  end

  defp day_state(day, first, last, booked) do
    cond do
      MapSet.member?(booked, day) -> :booked
      Date.compare(day, first) == :lt or Date.compare(day, last) == :gt -> :unavailable
      true -> :free
    end
  end

  @doc "Monday-first weekday initials for the calendar header."
  defdelegate weekday_initials, to: VutuvWeb.UI

  def status_label(%Ad{} = ad) do
    case Ad.status(ad) do
      :pending -> gettext("Waiting for approval")
      :approved -> gettext("Approved")
      :rejected -> gettext("Rejected")
      :cancelled -> gettext("Cancelled")
    end
  end

  @doc """
  The state pill shown on the member dashboard and the admin review page.
  Green once approved, red when turned down, neutral while the review is
  pending and once withdrawn (amber is reserved for moderation notices).
  """
  attr(:ad, Ad, required: true)

  def status_badge(assigns) do
    assigns = assign(assigns, :status, Ad.status(assigns.ad))

    ~H"""
    <span
      data-ad-status={@status}
      class={[
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-bold",
        status_colors(@status)
      ]}
    >
      {status_label(@ad)}
    </span>
    """
  end

  defp status_colors(:approved),
    do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200"

  defp status_colors(:rejected),
    do: "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-200"

  defp status_colors(_pending_or_cancelled),
    do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"

  @doc "A booked day the way the reader writes dates (`Vutuv.ViewerClock`)."
  def day_label(%Date{} = day), do: Vutuv.ViewerClock.format(day, :date)

  @doc """
  What a purchase runs for: the day itself, or the stretch a block covers. One
  function, so the flash, the preview and "My bookings" cannot each spell a
  week differently.
  """
  def period_label(%Date{} = first, days) when days <= 1, do: day_label(first)

  def period_label(%Date{} = first, days) do
    gettext("%{from} to %{to}",
      from: day_label(first),
      to: day_label(Date.add(first, days - 1))
    )
  end

  @doc """
  What a purchase of `days` costs, net. A single day is quoted per day, as the
  offer page quotes it; a block is quoted as the one figure it is invoiced at,
  because "2.000,00 € pro Tag" would be a lie.
  """
  def block_price(days) when days <= 1, do: AdsDoc.price_display()

  def block_price(days) do
    gettext("%{amount} € for the whole period (net)",
      amount: UI.euro_cents(block_cents(days))
    )
  end

  @doc "The VAT line for a purchase of `days`, or nil where none is charged."
  def block_vat(days), do: AdsDoc.vat_display(block_cents(days))

  @doc """
  What a booking was made at, from the price stamped on its rows rather than
  from today's list: a single day per day, a block as its own total.
  """
  def booked_price(%{days: 1, price_cents: cents}), do: AdsDoc.price_display(cents)

  def booked_price(%{price_cents: cents}),
    do: gettext("%{amount} € for the whole period (net)", amount: UI.euro_cents(cents))

  defp block_cents(days), do: Ads.block_price_cents(days) || Ads.price_cents()

  @doc "A day in the reader's writing, with the ISO date for machines."
  attr(:day, Date, required: true)

  def day_time(assigns) do
    ~H"""
    <time datetime={Date.to_iso8601(@day)}>{day_label(@day)}</time>
    """
  end

  # "Bookings are open through <day>.", translated as one sentence.
  defp open_through(assigns) do
    {before, rest} =
      split_marker(gettext("Bookings are open through %{last}.", last: "{last}"), "{last}")

    assigns = assign(assigns, before: before, rest: rest, last: Ads.last_bookable_day())

    ~H"""
    {@before}<.day_time day={@last} />{@rest}
    """
  end

  @doc """
  Where a booking ended up, shown under it for its booker and on the review
  pages: its numbers once its day came, and why it was turned down.
  """
  attr(:ad, Ad, required: true)

  def ad_outcome(assigns) do
    assigns = assign(assigns, reach: reach_line(assigns.ad), status: Ad.status(assigns.ad))

    ~H"""
    <p :if={@reach} data-ad-reach class="mb-0 mt-2 text-sm text-slate-700 dark:text-slate-300">
      {@reach}
    </p>
    <p :if={@status == :rejected} class="mb-0 mt-2 text-sm text-slate-700 dark:text-slate-300">
      {gettext("Not approved: %{reason}", reason: @ad.rejection_reason)}
    </p>
    """
  end

  @doc """
  The booker's controls under one of their bookings: withdrawing it while it
  waits for approval.
  """
  attr(:ad, Ad, required: true)

  def booking_actions(assigns) do
    assigns = assign(assigns, :withdrawable?, Ads.withdrawable?(assigns.ad))

    ~H"""
    <p :if={Ad.status(@ad) == :pending} class="mb-0 mt-3 text-xs text-slate-600 dark:text-slate-400">
      {gettext(
        "We review every ad before it runs. Until then you can cancel the booking free of charge."
      )}
    </p>
    <.form
      :if={Ad.status(@ad) == :pending}
      for={%{}}
      id={"cancel-booking-#{@ad.id}"}
      action={~p"/system/ads/#{@ad}/cancel"}
      method="post"
      class="mt-2"
    >
      <.button
        type="submit"
        variant="danger-ghost"
        data-confirm={gettext("Cancel this booking? The day is then free for others.")}
      >
        {gettext("Cancel booking")}
      </.button>
    </.form>

    <%!-- Taking an approved ad off the site costs the whole booking, so it is
    not a `data-confirm` one-liner: the price of the act is the thing that has
    to be read, and a native confirm cannot say it in more than a sentence. --%>
    <div :if={@withdrawable?} class="mt-3">
      <.button variant="danger-ghost" data-modal-open={"withdraw-#{@ad.id}"}>
        {gettext("Take this ad off the site")}
      </.button>
    </div>
    <.modal_dialog :if={@withdrawable?} id={"withdraw-#{@ad.id}"}>
      <h2 class="text-lg font-bold">{gettext("Take this ad off the site?")}</h2>
      <p class="mt-3 text-sm text-slate-700 dark:text-slate-300">
        {gettext("It stops showing today. There is no money back: the booking was approved and the invoice stands.")}
      </p>
      <p class="mt-2 text-sm text-slate-700 dark:text-slate-300">
        {gettext("Days that have already run stay as they are.")}
      </p>
      <div class="mt-5 flex flex-wrap items-center justify-end gap-3">
        <.button variant="secondary" data-modal-close>
          {gettext("Keep it running")}
        </.button>
        <.form for={%{}} id={"withdraw-form-#{@ad.id}"} action={~p"/system/ads/#{@ad}/withdraw"} method="post">
          <.button type="submit" variant="danger">
            {gettext("Take it off, no money back")}
          </.button>
        </.form>
      </div>
    </.modal_dialog>
    """
  end

  @doc """
  How often a booking's card was seen and its link clicked, once its day has
  come; nil before that.
  """
  def reach_line(%Ad{} = ad) do
    if Date.compare(ad.day, Ads.today()) != :gt do
      Enum.join(
        [
          ngettext("seen %{formatted} time", "seen %{formatted} times", ad.views_count,
            formatted: delimited_count(ad.views_count)
          ),
          ngettext("%{formatted} click", "%{formatted} clicks", ad.clicks_count,
            formatted: delimited_count(ad.clicks_count)
          )
        ],
        " · "
      )
    end
  end
end
