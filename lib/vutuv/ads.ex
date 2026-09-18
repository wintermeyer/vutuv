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
  `current_banner/0` is what `VutuvWeb.AdServing` hands a profile or the feed -
  the **approved** ad on its day, the house ad (an ad for the ad system) on
  days nobody booked (or where approval never came). A member sees at most one
  ad an hour and none for the rest of the day after closing one
  (`eligible?/3`), and the booked ads they saw are kept for them
  (`record_sighting/3`); a visitor without an account sees the ad on every
  profile.

  Day boundaries are German local time, computed with the fixed EU DST rule
  (see `berlin_date/1`) because the project deliberately carries no timezone
  database dependency.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Ads.Ad
  alias Vutuv.Ads.Sighting
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.UUIDv7

  # The fixed price per day, in cents net (350 EUR). Stamped onto every
  # booking so old rows keep the price that was agreed.
  @price_cents 35_000

  # Days between booking and the earliest bookable day: every ad is approved
  # by an admin before it runs, and this is the room for that review.
  @approval_lead_days 3

  # The booking window reaches to the end of next month, so the booking page
  # shows availability as two full month calendars and bookings stay
  # near-term. Widen by bumping this one knob (the calendar follows).
  @booking_window_months 1

  # At most one ad an hour per member.
  @hour 3600

  # How long a member's seen ads are kept (`forget_old_sightings/1`), and how
  # many the history page shows at a time.
  @sighting_days 90
  @seen_page 20

  # What a block of consecutive days costs, net, as a package price rather than
  # a percentage: a round figure is what gets quoted on the phone, and the
  # discount is then whatever the arithmetic says. The month is cheaper per day
  # than the week because it binds the whole inventory - there is one slot a
  # day, so a month sold is a month nobody else can buy.
  @tiers [
    %{days: 1, cents: 35_000},
    %{days: 7, cents: 200_000},
    %{days: 30, cents: 750_000}
  ]

  def price_cents, do: @price_cents

  @doc """
  The lengths that can be booked and what each costs, cheapest per day last.
  Every price in the ad system is derived from this list, so the offer page,
  the booking form and the invoice cannot quote three different numbers.
  """
  def tiers, do: @tiers

  @doc "The tier for a block of `days`, or nil where that length is not sold."
  def tier(days) when is_integer(days), do: Enum.find(@tiers, &(&1.days == days))

  @doc "What a block of `days` costs, net, or nil for a length nobody sells."
  def block_price_cents(days) do
    case tier(days) do
      nil -> nil
      %{cents: cents} -> cents
    end
  end

  @doc """
  What a day of a block costs against a day bought on its own, as whole
  percent: 0 for the single day, 43 for a month at 250 € against 350 €.
  """
  def tier_discount_percent(%{days: days, cents: cents}) do
    round((1 - cents / (days * @price_cents)) * 100)
  end

  @doc "The per-day figure a block works out at, net, rounded to the cent."
  def tier_day_cents(%{days: days, cents: cents}), do: round(cents / days)

  @doc """
  The VAT rate added on top of every quoted price, in percent, from
  `config :vutuv, :ads_vat_percent` (`ADS_VAT_PERCENT`, default 19 — the German
  rate this installation invoices at). Every price in the ad system is **net**;
  an installation in another country sets its own rate, and `0` drops the VAT
  line from the offer, the booking form and both mails.
  """
  def vat_percent, do: Application.get_env(:vutuv, :ads_vat_percent, 19)

  @doc "`cents` plus VAT, rounded to the cent (35_000 -> 41_650 at 19 %)."
  def gross_cents(cents) when is_integer(cents), do: cents + vat_cents(cents)

  @doc "The VAT on `cents`, rounded to the cent."
  def vat_cents(cents) when is_integer(cents), do: round(cents * vat_percent() / 100)

  @doc """
  Whether the daily text-ad system is switched on, from
  `config :vutuv, :ads_enabled` (default **off**). The single gate the rest
  of the app asks: when off, no ad serves (`VutuvWeb.AdServing`), the
  public `/system/ads` flow and the admin review dashboard answer 404
  (`VutuvWeb.Plug.RequireAdsEnabled`), and nothing can be booked. `"ads"`
  stays a reserved slug regardless (see `Vutuv.Accounts.ReservedSlugs`), so
  the handle stays free for when the system is turned back on.
  """
  def enabled?, do: Application.get_env(:vutuv, :ads_enabled, false)

  @doc "The earliest day a new booking may pick (today + #{@approval_lead_days}, Berlin)."
  def first_bookable_day, do: first_bookable_day(today())

  defp first_bookable_day(today), do: Date.add(today, @approval_lead_days)

  @doc """
  The last bookable day: the end of the month #{@booking_window_months} month(s)
  out - the last grid of the availability calendar on the booking page.
  """
  def last_bookable_day, do: last_bookable_day(today())

  defp last_bookable_day(today),
    do: today |> Date.shift(month: @booking_window_months) |> Date.end_of_month()

  @doc "Every taken day inside the booking window, as a MapSet (the calendar)."
  def booked_days, do: booked_days_in(first_bookable_day(), last_bookable_day())

  defp booked_days_in(first, last) do
    from(a in standing(), where: a.day >= ^first and a.day <= ^last, select: a.day)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The days a block of `days` starting on `first` would occupy.
  """
  def block_days(%Date{} = first, days) when is_integer(days) and days > 0,
    do: Enum.map(0..(days - 1), &Date.add(first, &1))

  @doc """
  Whether a block of `days` can start on `first`: every day of it free and
  inside the booking window. The calendar offers only such days as a start, so
  a member never picks a week whose Thursday is gone.
  """
  def free_block?(%Date{} = first, days, taken \\ nil) do
    taken = taken || booked_days()
    block = block_days(first, days)

    Date.compare(List.last(block), last_bookable_day()) != :gt and
      Enum.all?(block, &(not MapSet.member?(taken, &1)))
  end

  @doc "The booking that holds `day`, or nil."
  def get_ad(%Date{} = day), do: Repo.one(from(a in standing(), where: a.day == ^day))

  # The bookings that hold their day: neither turned down nor withdrawn. The
  # unique index on `day` covers exactly these.
  defp standing, do: from(a in Ad, where: is_nil(a.rejected_at) and is_nil(a.cancelled_at))

  # Those still waiting for an admin.
  defp pending, do: from(a in standing(), where: is_nil(a.approved_at))

  @doc """
  The ad with this id, with `preloads` (the admin detail page names the booker
  and the admins who decided), or nil (also on a malformed id).
  """
  def get_ad_by_id(id, preloads \\ []) do
    UUIDv7.with_cast(id, &(Ad |> Repo.get(&1) |> Repo.preload(preloads)))
  end

  @doc """
  What the banner shows right now: `{:ad, ad}` on a booked day whose ad has
  been approved, `:house` (the ad for the ad system) otherwise. An
  unapproved ad never serves.
  """
  def current_banner do
    case Repo.one(serving_today()) do
      nil -> :house
      ad -> {:ad, ad}
    end
  end

  @doc """
  Books `attrs`'s day for `user`, mails the booking (billing data + ad text)
  to the operator and confirms it to the booker. The unique index on `day`
  decides races; payment is by manually sent invoice, so nothing else
  happens here.

  `days` books that many consecutive days as one purchase (`tiers/0`): one row
  per day sharing a `group_id`, inserted in a single transaction, so a day
  somebody else took in the meantime fails the whole block rather than leaving
  a member holding four days of the week they paid for.
  """
  def book_ad(user, attrs, days \\ 1)

  def book_ad(user, attrs, 1) do
    %Ad{user_id: user.id, price_cents: @price_cents}
    |> Ad.changeset(attrs)
    |> Repo.insert()
    |> announce_booking(user)
  end

  def book_ad(user, attrs, days) when is_integer(days) do
    case block_changesets(user, attrs, days) do
      {:ok, changesets} -> changesets |> insert_block() |> announce_booking(user)
      {:error, changeset} -> {:error, changeset}
    end
  end

  # One changeset per day of the block, all carrying the same group and the
  # same text. The first day is the one the form collected, so it is the one
  # that reports a length or a window error back to the field.
  defp block_changesets(user, attrs, days) do
    with {:ok, total} <- block_total(days),
         {:ok, first} <- first_day(attrs, days) do
      group_id = UUIDv7.generate()

      {:ok,
       total
       |> share_cents(days)
       |> Enum.with_index()
       |> Enum.map(fn {cents, offset} ->
         %Ad{user_id: user.id, price_cents: cents, group_id: group_id}
         |> Ad.changeset(%{attrs | "day" => Date.to_iso8601(Date.add(first, offset))})
       end)}
    end
  end

  defp block_total(days) do
    case block_price_cents(days) do
      nil -> {:error, length_error(days)}
      cents -> {:ok, cents}
    end
  end

  # The day the block starts, refused here rather than N times over: only the
  # first day's changeset is shown, so a last day past the window has to be
  # said about the day the member actually picked.
  defp first_day(attrs, days) do
    changeset = Ad.changeset(%Ad{price_cents: @price_cents}, attrs)

    case Ecto.Changeset.fetch_change(changeset, :day) do
      {:ok, first} ->
        last = Date.add(first, days - 1)

        if Date.compare(last, last_bookable_day()) == :gt do
          {:error,
           Ecto.Changeset.add_error(changeset, :day, "is outside the booking window",
             validation: :block_window
           )}
        else
          {:ok, first}
        end

      :error ->
        {:error, %{changeset | action: :insert}}
    end
  end

  defp length_error(days) do
    %Ad{price_cents: @price_cents}
    |> Ad.changeset(%{})
    |> Ecto.Changeset.add_error(:day, "cannot be booked for #{days} days")
    |> Map.put(:action, :insert)
  end

  # The block's price split over its days so the shares add up to it exactly:
  # 200_000 over 7 is 28_571 six times and 28_574 once. Nobody reads a share -
  # every page shows the block's own total - but a day cancelled out of a block
  # has to leave the rest adding up to something real.
  defp share_cents(total, days) do
    share = div(total, days)
    [share + rem(total, days) | List.duplicate(share, days - 1)]
  end

  defp insert_block(changesets) do
    case Repo.transaction(fn -> Enum.reduce_while(changesets, nil, &insert_or_rollback/2) end) do
      {:ok, last} -> {:ok, first_of_group(last)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # One day of the block taken in the meantime takes the whole purchase down.
  defp insert_or_rollback(changeset, _acc) do
    case Repo.insert(changeset) do
      {:ok, ad} -> {:cont, ad}
      {:error, changeset} -> {:halt, Repo.rollback(changeset)}
    end
  end

  defp first_of_group(%Ad{group_id: nil} = ad), do: ad

  defp first_of_group(%Ad{group_id: group_id}),
    do: Repo.one(from(a in Ad, where: a.group_id == ^group_id, order_by: a.day, limit: 1))

  defp announce_booking({:ok, ad}, user) do
    ad
    |> Emailer.ad_booking_email(user)
    |> Emailer.deliver()

    tell_booker(user, ad, &Emailer.ad_booked_email/3)
    {:ok, ad}
  end

  defp announce_booking({:error, changeset}, _user), do: {:error, changeset}

  @doc "Changeset for the booking form."
  def change_ad(%Ad{} = ad, attrs \\ %{}), do: Ad.changeset(ad, attrs)

  @doc """
  The check-before-buying step: validates `attrs` like `book_ad/2` would
  (including whether the day is still free, which `book_ad/2` only learns
  from the unique index) and returns the would-be ad without persisting
  anything - the preview page renders it through the real banner component.
  """
  def preview_ad(attrs, days \\ 1) do
    %Ad{price_cents: block_price_cents(days) || @price_cents, group_id: block_group(days)}
    |> Ad.changeset(attrs)
    |> validate_block_free(days)
    |> Ecto.Changeset.apply_action(:insert)
  end

  # The preview is never saved, so its group id only has to say "this is a
  # block" to whatever renders it.
  defp block_group(1), do: nil
  defp block_group(_days), do: UUIDv7.generate()

  defp validate_block_free(changeset, days) do
    Ecto.Changeset.validate_change(changeset, :day, fn :day, day ->
      cond do
        Date.compare(Date.add(day, days - 1), last_bookable_day()) == :gt ->
          [day: "is outside the booking window"]

        not free_block?(day, days) ->
          [day: "has already been booked"]

        true ->
          []
      end
    end)
  end

  @doc """
  The admin review gate: stamps `approved_at` and the approving admin, after
  which the ad serves on its day, and tells the booker. Idempotent -
  approving an already approved ad keeps the original stamp and sends
  nothing (so two admins clicking at once cannot reassign the approval). A
  rejected or cancelled booking is `{:error, :not_pending}`.
  """
  def approve_ad(%Ad{} = ad, admin) do
    if Ad.status(ad) == :approved do
      {:ok, ad}
    else
      case move(ad, pending(), approved_at: DateTime.utc_now(:second), approved_by_id: admin.id) do
        {:ok, approved} ->
          tell_booker(approved, &Emailer.ad_approved_email/3)
          {:ok, approved}

        {:error, :not_pending} ->
          approved_meanwhile(ad)
      end
    end
  end

  # Another admin approved it between this one's page load and click: their
  # approval stands, and it is the one asked for.
  defp approved_meanwhile(%Ad{id: id}) do
    current = Repo.get!(Ad, id)
    if Ad.status(current) == :approved, do: {:ok, current}, else: {:error, :not_pending}
  end

  @doc """
  Turns a booking that waits for approval down: the day is free again, and
  the booker is told `reason`, which is required. `{:error, changeset}` for a
  missing reason, `{:error, :not_pending}` once the booking was decided or
  withdrawn.
  """
  def reject_ad(%Ad{} = ad, admin, reason) do
    with {:ok, checked} <-
           ad |> Ad.rejection_changeset(reason) |> Ecto.Changeset.apply_action(:update),
         {:ok, rejected} <-
           move(ad, pending(),
             rejected_at: DateTime.utc_now(:second),
             rejected_by_id: admin.id,
             rejection_reason: checked.rejection_reason
           ) do
      tell_booker(rejected, &Emailer.ad_rejected_email/3)
      {:ok, rejected}
    end
  end

  @doc """
  The booker withdraws their own booking, which they may only while it waits
  for approval: once approved it is binding. The day is free again and the
  operator is told, since the invoice may already be written.
  `{:error, :not_found}` for somebody else's booking.
  """
  def cancel_booking(%Ad{user_id: user_id} = ad, %User{id: user_id} = booker)
      when is_binary(user_id) do
    with {:ok, cancelled} <-
           move(ad, pending(), cancelled_at: DateTime.utc_now(:second), cancelled_by_id: user_id) do
      cancelled
      |> Emailer.ad_cancellation_email(booker)
      |> Emailer.deliver()

      {:ok, cancelled}
    end
  end

  def cancel_booking(%Ad{}, %User{}), do: {:error, :not_found}

  @doc """
  An admin withdraws a booking that has not run yet, approved or not (on the
  booker's request, say), and the booker is told. The day is free again.
  """
  def cancel_ad(%Ad{} = ad, admin) do
    upcoming = from(a in standing(), where: a.day >= ^today())

    with {:ok, cancelled} <-
           move(ad, upcoming, cancelled_at: DateTime.utc_now(:second), cancelled_by_id: admin.id) do
      tell_booker(cancelled, &Emailer.ad_cancelled_email/3)
      {:ok, cancelled}
    end
  end

  # Sets `changes` on `ad` only while its row still matches `query`, in the one
  # statement that also hands the rows back, so an admin and the booker (or two
  # admins) acting at once cannot both move it.
  #
  # A week or a month was bought as one thing, so this is where that holds for
  # every decision at once: the statement takes the whole group, and approving,
  # rejecting or cancelling any day of a block does it to all of them. Anything
  # of the block already decided simply fails `query` and stays as it is.
  defp move(%Ad{} = ad, query, changes) do
    case Repo.update_all(from(a in query, where: ^same_purchase(ad), select: a), set: changes) do
      {0, _} -> {:error, :not_pending}
      {_n, moved} -> {:ok, Enum.min_by(moved, & &1.day, Date)}
    end
  end

  defp same_purchase(%Ad{id: id, group_id: nil}), do: dynamic([a], a.id == ^id)
  defp same_purchase(%Ad{group_id: group_id}), do: dynamic([a], a.group_id == ^group_id)

  # A mail about their booking to the booker, off the request path. The
  # account may be gone (`user_id` is nilified) or have no address.
  defp tell_booker(%Ad{user_id: nil}, _build), do: :ok
  defp tell_booker(%Ad{} = ad, build), do: tell_booker(Repo.get(User, ad.user_id), ad, build)

  defp tell_booker(nil, _ad, _build), do: :ok

  defp tell_booker(%User{} = user, ad, build),
    do: Emailer.deliver_to_member(user, &build.(&1, &2, ad))

  @doc "One more card of `banner` seen (a booked ad; the house ad counts nothing)."
  def count_view({:ad, %Ad{id: id}}), do: bump(id, :views_count)
  def count_view(:house), do: :ok

  @doc "One more click on `banner`'s link (a booked ad; the house ad counts nothing)."
  def count_click({:ad, %Ad{id: id}}), do: bump(id, :clicks_count)
  def count_click(:house), do: :ok

  defp bump(id, field) do
    Repo.update_all(from(a in Ad, where: a.id == ^id), inc: [{field, 1}])
    :ok
  end

  @doc "All bookings of `user`, newest day first (the member dashboard)."
  def user_ads(user) do
    Repo.all(from(a in Ad, where: a.user_id == ^user.id, order_by: [desc: a.day]))
  end

  @doc """
  A member's bookings as the things they bought: one entry per purchase, a
  block of days folded into one. `ad` is its first day (the one every control
  acts on, since `move/3` takes the whole group), `days` how many it runs and
  `price_cents` what the whole block cost.
  """
  def user_bookings(user) do
    user
    |> user_ads()
    |> Enum.group_by(&purchase_key/1)
    |> Enum.map(fn {_key, ads} ->
      sorted = Enum.sort_by(ads, & &1.day, Date)

      %{
        ad: hd(sorted),
        last_day: List.last(sorted).day,
        days: length(sorted),
        price_cents: Enum.sum(Enum.map(sorted, & &1.price_cents))
      }
    end)
    |> Enum.sort_by(& &1.ad.day, {:desc, Date})
  end

  # A block counts as one purchase; a single day is its own.
  defp purchase_key(%Ad{group_id: nil, id: id}), do: {:ad, id}
  defp purchase_key(%Ad{group_id: group_id}), do: {:group, group_id}

  @doc "How many days this ad was bought as part of: 1 unless it is a block."
  def purchase_days(%Ad{} = ad), do: purchase(ad).days

  @doc """
  The purchase this ad belongs to, in one query: its first and last day, how
  many days it runs and what the whole thing cost. Every mail about a booking
  reads it, because a block's rows each carry only their share of the price and
  the day they happen to fall on - neither of which is what the invoice says.
  """
  def purchase(%Ad{group_id: nil} = ad),
    do: %{days: 1, first_day: ad.day, last_day: ad.day, price_cents: ad.price_cents}

  def purchase(%Ad{group_id: group_id}) do
    from(a in Ad,
      where: a.group_id == ^group_id,
      select: %{
        days: count(a.id),
        first_day: min(a.day),
        last_day: max(a.day),
        price_cents: sum(a.price_cents)
      }
    )
    |> Repo.one()
  end

  @doc """
  The admin dashboard's upcoming bookings (today included) in serving order,
  bookers preloaded, as `{standing, withdrawn}`: the ones that still hold
  their day, and the ones rejected or cancelled.
  """
  def upcoming_ads do
    from(a in Ad, where: a.day >= ^today(), order_by: [asc: a.day, asc: a.id], preload: [:user])
    |> Repo.all()
    |> Enum.split_with(&(Ad.status(&1) in [:pending, :approved]))
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
    Repo.aggregate(from(a in pending(), where: a.day >= ^today()), :count)
  end

  @doc """
  The first free day inside the booking window
  (`first_bookable_day/0`..`last_bookable_day/0`), nil when it is sold out.
  """
  def next_available_day do
    today = today()
    first = first_bookable_day(today)
    last = last_bookable_day(today)
    booked = booked_days_in(first, last)

    Enum.find(Date.range(first, last), &(not MapSet.member?(booked, &1)))
  end

  @doc """
  A member's two frequency rules, over their `users.ad_seen_at` and
  `users.ads_dismissed_on`: no ad within an hour of the last one (`seen_at`),
  and none for the rest of a Berlin day on which one was closed
  (`dismissed_on`). Either may be nil.
  """
  def eligible?(seen_at, dismissed_on, now \\ DateTime.utc_now()) do
    dismissed_on != today() and not within_the_hour?(seen_at, now)
  end

  @doc "Whether `then` lies less than an hour before `now` (false for nil)."
  def within_the_hour?(nil, _now), do: false
  def within_the_hour?(then, now), do: DateTime.diff(now, then) < @hour

  @doc """
  Records that `user` has seen `banner`: takes the member's hour and, for a
  booked ad, counts the sighting up on its row (the member's history of seen
  ads) and the view on the ad. The house ad takes the hour and leaves no row.

  The hour is taken only while it is free, in the same statement that checks
  it, so two tabs whose cards come into view within one hour count once:
  `:capped` for the later one, which then should not show its card.
  """
  def record_sighting(%User{} = user, banner, now \\ DateTime.utc_now(:second)) do
    free_since = DateTime.add(now, -@hour)

    {taken, _} =
      Repo.update_all(
        from(u in User,
          where: u.id == ^user.id and (is_nil(u.ad_seen_at) or u.ad_seen_at <= ^free_since)
        ),
        set: [ad_seen_at: now]
      )

    if taken == 1, do: count_sighting(user, banner, now), else: :capped
  end

  defp count_sighting(user, banner, now) do
    case banner do
      {:ad, %Ad{id: ad_id}} ->
        Repo.insert_all(
          Sighting,
          [
            %{
              id: UUIDv7.generate(),
              user_id: user.id,
              ad_id: ad_id,
              first_seen_at: now,
              last_seen_at: now,
              times_seen: 1
            }
          ],
          on_conflict: [set: [last_seen_at: now], inc: [times_seen: 1]],
          conflict_target: [:user_id, :ad_id]
        )

      :house ->
        nil
    end

    count_view(banner)
  end

  @doc "How many days a member's seen ads are kept."
  def sighting_days, do: @sighting_days

  @doc """
  A member's seen ads for their history page, as `{rows, more?}`: sightings
  with the ad preloaded, the most recently seen first. Options: `query`
  (matched against the title, the text and the link without its query), `limit` (#{@seen_page}) and `after` (the
  `last_seen_at` and `id` of the last row of the page before).
  """
  def seen_ads(%User{} = user, opts \\ []) do
    limit = Keyword.get(opts, :limit, @seen_page)

    rows =
      from([s, ad: a] in sightings_of(user, opts[:query]),
        order_by: [desc: s.last_seen_at, desc: s.id],
        limit: ^(limit + 1),
        preload: [ad: a]
      )
      |> after_row(opts[:after])
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  @doc "How many of a member's seen ads match `query` (all of them for nil)."
  def count_seen_ads(%User{} = user, query) do
    user |> sightings_of(query) |> Repo.aggregate(:count)
  end

  defp sightings_of(user, text) do
    query = from(s in Sighting, join: a in assoc(s, :ad), as: :ad, where: s.user_id == ^user.id)

    case SearchText.normalize_search(text) do
      nil ->
        query

      term ->
        pattern = SearchText.contains(term)

        # The link is matched as the card shows it, without query or fragment
        # (`chr(63)` is `?`, which a fragment string cannot hold).
        from([ad: a] in query,
          where:
            ilike(a.title, ^pattern) or ilike(a.body, ^pattern) or
              ilike(
                fragment("split_part(split_part(?, chr(63), 1), chr(35), 1)", a.url),
                ^pattern
              )
        )
    end
  end

  defp after_row(query, nil), do: query

  defp after_row(query, %{last_seen_at: at, id: id}) do
    from(s in query, where: s.last_seen_at < ^at or (s.last_seen_at == ^at and s.id < ^id))
  end

  @doc """
  Deletes the sightings last seen more than #{@sighting_days} days before
  `now`, returning how many went (`Vutuv.Ads.SightingSweeper`).
  """
  def forget_old_sightings(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@sighting_days * 86_400)
    # Found through the ads they belong to (`day` and `ad_id` are indexed,
    # `last_seen_at` is not). An ad is seen on its Berlin day, which starts
    # up to two hours before the UTC one, hence the day after the cutoff.
    ads = from(a in Ad, where: a.day <= ^Date.add(DateTime.to_date(cutoff), 1), select: a.id)

    {count, _} =
      Repo.delete_all(
        from(s in Sighting, where: s.ad_id in subquery(ads) and s.last_seen_at < ^cutoff)
      )

    count
  end

  @doc "The ✕: no further ad for `user` until Berlin midnight, on any device."
  def dismiss_today(%User{} = user) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [ads_dismissed_on: today()])
    :ok
  end

  @doc """
  The ad with this id if it may still serve now: approved and booked for
  today. Nil for anything else, a malformed id included, so a page reconnecting
  after midnight does not bring yesterday's ad back.
  """
  def todays_ad(id) do
    UUIDv7.with_cast(id, fn id -> Repo.one(from(a in serving_today(), where: a.id == ^id)) end)
  end

  # What may serve: today's standing ad, once an admin approved it. An ad
  # booked in the old Markdown format has no title and no longer serves.
  defp serving_today do
    from(a in standing(),
      where: a.day == ^today() and not is_nil(a.approved_at) and not is_nil(a.title)
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
