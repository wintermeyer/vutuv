defmodule Vutuv.Ads.Ad do
  @moduledoc """
  A booked text ad: one per calendar day (Europe/Berlin), paid by invoice.

  `content` is Markdown (rendered through `VutuvWeb.Markdown.render/1`, never
  raw) and capped at 2048 characters. The billing fields are the invoice
  address the booker entered; together with `price_cents` they make the row
  the durable record of the order (the invoice itself is sent manually).
  """

  use VutuvWeb, :model
  use Gettext, backend: VutuvWeb.Gettext

  @content_max_length 2048

  schema "ads" do
    field(:day, :date)
    field(:content, :string)
    field(:price_cents, :integer)

    field(:billing_name, :string)
    field(:billing_company, :string)
    field(:billing_street, :string)
    field(:billing_zip_code, :string)
    field(:billing_city, :string)
    field(:billing_country, :string)
    field(:vat_id, :string)

    # The admin review gate: an ad only serves once approved_at is set
    # (see Vutuv.Ads.approve_ad/2 and current_banner/0).
    field(:approved_at, :utc_datetime)
    belongs_to(:approved_by, Vutuv.Accounts.User)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  def content_max_length, do: @content_max_length

  @doc """
  The booking changeset. `user_id` and `price_cents` are set programmatically
  by `Vutuv.Ads.book_ad/2`, never cast from params.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [
      :day,
      :content,
      :billing_name,
      :billing_company,
      :billing_street,
      :billing_zip_code,
      :billing_city,
      :billing_country,
      :vat_id
    ])
    |> validate_required([
      :day,
      :content,
      :billing_name,
      :billing_street,
      :billing_zip_code,
      :billing_city,
      :billing_country
    ])
    |> validate_length(:content, max: @content_max_length)
    # The billing fields are free-text varchar(255) columns: an oversized value
    # must be a changeset error, never a raised Postgres 22001 on booking.
    |> validate_length(:billing_name, max: 255)
    |> validate_length(:billing_company, max: 255)
    |> validate_length(:billing_street, max: 255)
    |> validate_length(:billing_zip_code, max: 255)
    |> validate_length(:billing_city, max: 255)
    |> validate_length(:billing_country, max: 255)
    |> validate_length(:vat_id, max: 255)
    |> validate_future_day()
    |> unique_constraint(:day, message: "has already been booked")
  end

  # Every ad is reviewed by an admin before it runs, so the earliest
  # bookable day leaves room for that: three days out (Berlin). Bookings are
  # also only accepted inside the calendar window the booking page shows
  # (through Vutuv.Ads.last_bookable_day/0).
  defp validate_future_day(changeset) do
    validate_change(changeset, :day, fn :day, day ->
      cond do
        Date.compare(day, Vutuv.Ads.first_bookable_day()) == :lt ->
          [day: "must be booked at least three days ahead"]

        Date.compare(day, Vutuv.Ads.last_bookable_day()) == :gt ->
          [day: "is outside the booking window"]

        true ->
          []
      end
    end)
  end
end
