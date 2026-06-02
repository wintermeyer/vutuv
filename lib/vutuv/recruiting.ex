defmodule Vutuv.Recruiting do
  @moduledoc """
  The Recruiting context. Handles recruiter packages,
  subscriptions, and coupons.
  """

  import Ecto.Query

  alias Vutuv.Recruiting.Coupon
  alias Vutuv.Recruiting.RecruiterPackage
  alias Vutuv.Recruiting.RecruiterSubscription
  alias Vutuv.Repo

  # ── Recruiter Packages ──

  def list_packages do
    Repo.all(RecruiterPackage)
  end

  def get_package!(id), do: Repo.get!(RecruiterPackage, id)

  def create_package(attrs) do
    %RecruiterPackage{} |> RecruiterPackage.changeset(attrs) |> Repo.insert()
  end

  def update_package(%RecruiterPackage{} = package, attrs) do
    package |> RecruiterPackage.changeset(attrs) |> Repo.update()
  end

  def delete_package!(%RecruiterPackage{} = package), do: Repo.delete!(package)

  # ── Recruiter Subscriptions ──

  def list_subscriptions(user) do
    Repo.all(from(s in RecruiterSubscription, where: s.user_id == ^user.id))
  end

  def get_subscription!(id), do: Repo.get!(RecruiterSubscription, id)

  def active_subscription(user_id), do: RecruiterSubscription.active_subscription(user_id)

  def create_subscription(user, attrs) do
    user
    |> Ecto.build_assoc(:recruiter_subscriptions)
    |> RecruiterSubscription.changeset(attrs)
    |> Repo.insert()
  end

  def update_subscription(%RecruiterSubscription{} = sub, attrs) do
    sub |> RecruiterSubscription.changeset(attrs) |> Repo.update()
  end

  def delete_subscription!(%RecruiterSubscription{} = sub), do: Repo.delete!(sub)

  # ── Coupons ──

  def list_coupons do
    Repo.all(Coupon)
  end

  def get_coupon!(id), do: Repo.get!(Coupon, id)

  def get_coupon_by_code(code) do
    Repo.get_by(Coupon, code: code)
  end

  def create_coupon(attrs) do
    %Coupon{} |> Coupon.changeset(attrs) |> Repo.insert()
  end

  def update_coupon(%Coupon{} = coupon, attrs) do
    coupon |> Coupon.changeset(attrs) |> Repo.update()
  end

  def delete_coupon!(%Coupon{} = coupon), do: Repo.delete!(coupon)
end
