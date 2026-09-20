defmodule Vutuv.Ads.DiscountCode do
  @moduledoc """
  A discount an admin hands out for ad bookings.

  **The code is the row's id** — a UUID v7, so it is unguessable and cannot
  collide with one already handed out. Whoever has it can type it into the
  booking wizard.

  **Percent or euro, never both.** A row carrying both would be a price nobody
  can compute, so the pair is checked here *and* by a database constraint: the
  money is the one thing that must not depend on a validation somebody forgot
  to run.

  A code with a `user` belongs to that member alone and is good once. A code
  without one may be used by anybody, once each (`Vutuv.Ads.Discounts`).
  """

  use VutuvWeb, :model

  alias Vutuv.Ads.DiscountRedemption

  @percent_min 1
  @percent_max 100
  @cents_min 100
  @cents_max 300_000

  # How long a new code runs by default: to the end of the month four months
  # out, so an admin making one in the last days of a month still hands out
  # something worth having.
  @default_months 4

  schema "ad_discount_codes" do
    field(:percent_off, :integer)
    field(:cents_off, :integer)
    field(:expires_on, :date)
    field(:note, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:created_by, Vutuv.Accounts.User)
    has_many(:redemptions, DiscountRedemption, foreign_key: :code_id)

    timestamps()
  end

  def percent_range, do: {@percent_min, @percent_max}
  def cents_range, do: {@cents_min, @cents_max}

  @doc "The expiry a new code gets unless the admin picks another."
  def default_expiry(today \\ Vutuv.BerlinTime.today()),
    do: today |> Date.shift(month: @default_months) |> Date.end_of_month()

  @doc """
  The admin's create form. `created_by_id` is set programmatically.

  `kind` ("percent" or "euro") decides which of the two amounts survives, so a
  form that has held both at some point cannot save both.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:percent_off, :cents_off, :expires_on, :note, :user_id])
    |> keep_one_amount(params)
    |> validate_required([:expires_on])
    |> validate_length(:note, max: 255)
    |> validate_number(:percent_off,
      greater_than_or_equal_to: @percent_min,
      less_than_or_equal_to: @percent_max
    )
    |> validate_number(:cents_off,
      greater_than_or_equal_to: @cents_min,
      less_than_or_equal_to: @cents_max
    )
    |> validate_one_amount()
    |> validate_future_expiry()
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:percent_off,
      name: :percent_or_cents,
      message: "must be a percentage or an amount, not both"
    )
  end

  # The form offers both fields and one radio; whichever kind is not chosen is
  # cleared, so switching back and forth cannot leave a stale number behind.
  defp keep_one_amount(changeset, %{"kind" => "euro"}),
    do: put_change(changeset, :percent_off, nil)

  defp keep_one_amount(changeset, %{"kind" => "percent"}),
    do: put_change(changeset, :cents_off, nil)

  defp keep_one_amount(changeset, _params), do: changeset

  defp validate_one_amount(changeset) do
    percent = get_field(changeset, :percent_off)
    cents = get_field(changeset, :cents_off)

    cond do
      percent && cents ->
        add_error(changeset, :percent_off, "must be a percentage or an amount, not both")

      is_nil(percent) and is_nil(cents) ->
        add_error(changeset, :percent_off, "needs a percentage or an amount")

      true ->
        changeset
    end
  end

  # A code that is already over is not a code, it is a support ticket.
  defp validate_future_expiry(changeset) do
    validate_change(changeset, :expires_on, fn :expires_on, day ->
      if Date.compare(day, Vutuv.BerlinTime.today()) == :lt,
        do: [expires_on: "is already over"],
        else: []
    end)
  end

  @doc "What this code takes off `cents`, never more than the price itself."
  def discount_cents(%__MODULE__{percent_off: percent}, cents) when is_integer(percent),
    do: min(round(cents * percent / 100), cents)

  def discount_cents(%__MODULE__{cents_off: off}, cents) when is_integer(off), do: min(off, cents)

  @doc "Whether the code is still inside its own window."
  def live?(%__MODULE__{expires_on: expires_on}, today \\ Vutuv.BerlinTime.today()),
    do: Date.compare(expires_on, today) != :lt

  @doc """
  The same window as `live?/2`, as a query, so a row read one at a time and a
  count taken over all of them cannot answer differently.
  """
  def live_query(today \\ Vutuv.BerlinTime.today()),
    do: from(c in __MODULE__, where: c.expires_on >= ^today)
end
