defmodule Vutuv.Recruiting.RecruiterPackage do
  @moduledoc false

  use VutuvWeb, :model

  schema "recruiter_packages" do
    field(:name, :string)
    field(:description, :string)
    field(:slug, :string)
    field(:price, :float)
    field(:currency, :string)
    field(:duration_in_months, :integer)
    field(:auto_renewal, :boolean, default: true)
    field(:offer_begins, :date)
    field(:offer_ends, :date)
    field(:max_job_postings, :integer)
    field(:only_with_coupon, :boolean, default: false)

    belongs_to(:locale, Vutuv.Accounts.Locale)

    has_many(:recruiter_subscriptions, Vutuv.Recruiting.RecruiterSubscription)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :name,
      :description,
      :slug,
      :locale_id,
      :price,
      :currency,
      :duration_in_months,
      :auto_renewal,
      :offer_begins,
      :offer_ends,
      :max_job_postings,
      :only_with_coupon
    ])
    |> validate_required([
      :name,
      :description,
      :locale_id,
      :price,
      :currency,
      :duration_in_months,
      :auto_renewal,
      :offer_begins,
      :offer_ends,
      :max_job_postings,
      :only_with_coupon
    ])
  end
end
