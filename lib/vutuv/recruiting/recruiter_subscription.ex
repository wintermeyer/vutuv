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
  Builds a changeset from client-supplied params.

  Only fields the subscriber may set are cast here. The privileged payment and
  billing fields (`:paid`, `:paid_on`, `:invoice_number`, `:invoiced_on`) are
  set server-side via `payment_changeset/2`, and the subscription dates are
  derived from the chosen package in `set_dates/1` — none of them are cast from
  user input, so a crafted request cannot grant itself free recruiter access.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :recruiter_package_id,
      :line1,
      :line2,
      :street,
      :zip_code,
      :city,
      :country,
      :coupon_code
    ])
    |> validate_required([:recruiter_package_id, :line1, :zip_code, :city, :country])
    |> foreign_key_constraint(:recruiter_package)
    |> set_dates()
  end

  @doc """
  Server-only changeset for the privileged payment / billing fields.

  Used when the server itself records a payment (e.g. redeeming a 100% coupon or
  an admin marking an invoice paid). Never build this from raw request params.
  """
  def payment_changeset(struct, params \\ %{}) do
    cast(struct, params, [:invoice_number, :invoiced_on, :paid, :paid_on])
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
