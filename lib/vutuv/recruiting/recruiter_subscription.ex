defmodule Vutuv.Recruiting.RecruiterSubscription do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.Recruiting.RecruiterPackage

  schema "recruiter_subscriptions" do
    field(:subscription_begins, :date)
    field(:subscription_ends, :date)
    field(:line1, :string)
    field(:line2, :string)
    field(:street, :string)
    field(:zip_code, :string)
    field(:city, :string)
    field(:country, :string)
    field(:invoice_number, :string)
    field(:invoiced_on, :date)
    field(:paid, :boolean, default: false)
    field(:paid_on, :date)
    field(:coupon_code, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:recruiter_package, Vutuv.Recruiting.RecruiterPackage)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :user_id,
      :recruiter_package_id,
      :subscription_begins,
      :line1,
      :line2,
      :street,
      :zip_code,
      :city,
      :country,
      :invoice_number,
      :invoiced_on,
      :paid,
      :paid_on,
      :coupon_code
    ])
    |> validate_required([:recruiter_package_id, :line1, :zip_code, :city, :country])
    |> foreign_key_constraint(:recruiter_package)
    |> set_dates()
  end

  defp set_dates(changeset) do
    case get_change(changeset, :recruiter_package_id) do
      nil ->
        changeset

      id ->
        case Vutuv.Repo.get(RecruiterPackage, id) do
          %RecruiterPackage{duration_in_months: months} ->
            today = Date.utc_today()
            ends_on = today |> Date.beginning_of_month() |> Date.shift(month: months)

            changeset
            |> put_change(:subscription_begins, today)
            |> put_change(:subscription_ends, ends_on)

          _ ->
            add_error(changeset, :recruiter_package_id, "Something went wrong")
        end
    end
  end

  def active_subscription(user_id) do
    case Vutuv.Repo.one(
           from(s in __MODULE__,
             where: s.user_id == ^user_id and s.subscription_ends > fragment("NOW()"),
             limit: 1
           )
         ) do
      nil -> nil
      sub -> Vutuv.Repo.preload(sub, [:recruiter_package])
    end
  end
end
