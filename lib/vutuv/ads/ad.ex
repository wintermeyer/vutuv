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
    |> validate_future_day()
    |> unique_constraint(:day, message: "has already been booked")
  end

  # Ads start at midnight Berlin time, so a day must be bookable in full:
  # tomorrow (Berlin) at the earliest.
  defp validate_future_day(changeset) do
    validate_change(changeset, :day, fn :day, day ->
      if Date.compare(day, Vutuv.Ads.today()) == :gt do
        []
      else
        [day: "must be a future day"]
      end
    end)
  end
end
