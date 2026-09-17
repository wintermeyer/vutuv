defmodule Vutuv.Ads.Ad do
  @moduledoc """
  A booked text ad: one per calendar day (Europe/Berlin), paid by invoice.

  The ad itself is plain text in the style of classic text ads: a `title` of
  up to 30 characters that links to `url`, and a `body` sentence of up to
  90. Readers see where the link goes as `display_url/1`. The billing
  fields are the invoice address the booker entered; together with
  `price_cents` they make the row the durable record of the order (the
  invoice itself is sent manually).
  """

  use VutuvWeb, :model
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.ChangesetHelpers

  @title_max_length 30
  @body_max_length 90
  @url_max_length 2048

  schema "ads" do
    field(:day, :date)
    field(:title, :string)
    field(:body, :string)
    field(:url, :string)
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

    # The two ways a booking ends before its day, both of which free the day:
    # an admin turns it down with a reason (`Vutuv.Ads.reject_ad/3`), or it is
    # withdrawn (`cancel_booking/2`, `cancel_ad/2`).
    field(:rejected_at, :utc_datetime)
    belongs_to(:rejected_by, Vutuv.Accounts.User)
    field(:rejection_reason, :string)
    field(:cancelled_at, :utc_datetime)
    belongs_to(:cancelled_by, Vutuv.Accounts.User)

    # Cards seen and title links clicked (`Vutuv.Ads.count_view/1`).
    field(:views_count, :integer, default: 0)
    field(:clicks_count, :integer, default: 0)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  def title_max_length, do: @title_max_length
  def body_max_length, do: @body_max_length

  @doc """
  Where a booking stands: `:pending` until an admin decides, then `:approved`
  or `:rejected`; `:cancelled` once withdrawn, whatever it was before.
  """
  def status(%__MODULE__{cancelled_at: at}) when not is_nil(at), do: :cancelled
  def status(%__MODULE__{rejected_at: at}) when not is_nil(at), do: :rejected
  def status(%__MODULE__{approved_at: at}) when not is_nil(at), do: :approved
  def status(%__MODULE__{}), do: :pending

  @doc "The reason a booking is turned down with, which the booker reads."
  def rejection_changeset(ad, reason) do
    ad
    |> cast(%{rejection_reason: reason}, [:rejection_reason])
    |> ChangesetHelpers.trim_fields([:rejection_reason])
    |> validate_required([:rejection_reason])
    |> validate_length(:rejection_reason, max: 2000)
  end

  @doc """
  Where an ad's link goes, as a reader checks it: the host without `www.` and
  the path, never the query or the fragment a booker's tracking rides on
  (`Vutuv.WebVerification.normalize_url/1`). Empty for an ad booked in the old
  Markdown format, which has no link.
  """
  def display_url(url), do: Vutuv.WebVerification.normalize_url(url)

  @doc """
  The booking changeset. `user_id` and `price_cents` are set programmatically
  by `Vutuv.Ads.book_ad/2`, never cast from params.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [
      :day,
      :title,
      :body,
      :url,
      :billing_name,
      :billing_company,
      :billing_street,
      :billing_zip_code,
      :billing_city,
      :billing_country,
      :vat_id
    ])
    |> ChangesetHelpers.trim_fields([:title, :body, :url])
    |> validate_required([
      :day,
      :title,
      :body,
      :url,
      :billing_name,
      :billing_street,
      :billing_zip_code,
      :billing_city,
      :billing_country
    ])
    |> validate_length(:title, max: @title_max_length)
    |> validate_length(:body, max: @body_max_length)
    |> validate_length(:url, max: @url_max_length)
    |> ChangesetHelpers.validate_url(:url)
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
