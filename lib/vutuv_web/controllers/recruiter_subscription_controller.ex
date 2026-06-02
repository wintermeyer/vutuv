defmodule VutuvWeb.RecruiterSubscriptionController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.Locale
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Recruiting.Coupon
  alias Vutuv.Recruiting.RecruiterSubscription

  def index(conn, _params) do
    user = Repo.preload(conn.assigns[:user], recruiter_subscriptions: :recruiter_package)
    render(conn, "index.html", recruiter_subscriptions: user.recruiter_subscriptions)
  end

  def new(conn, _params) do
    changeset = RecruiterSubscription.changeset(%RecruiterSubscription{})
    active_subscription = RecruiterSubscription.active_subscription(conn.assigns[:user_id])
    recruiter_packages = get_recruiter_packages(conn.assigns[:user])
    has_valid_coupons = has_valid_coupons(conn.assigns[:user])

    render(conn, "new.html",
      changeset: changeset,
      active_subscription: active_subscription,
      recruiter_packages: recruiter_packages,
      has_valid_coupons: has_valid_coupons
    )
  end

  def create(conn, %{"recruiter_subscription" => recruiter_subscription_params}) do
    changeset =
      Ecto.build_assoc(conn.assigns[:user], :recruiter_subscriptions)
      |> RecruiterSubscription.changeset(recruiter_subscription_params)

    case Repo.insert(changeset) do
      {:ok, recruiter_subscription} ->
        maybe_redeem_coupon(recruiter_subscription)

        # Send an email to the client
        Emailer.payment_information_email(
          recruiter_subscription,
          conn.assigns[:user],
          VutuvWeb.UserHelpers.email(conn.assigns[:user])
        )
        |> Vutuv.Mailer.deliver()

        # Send an email to accounting
        accounting_email = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:accounting_email]

        if accounting_email do
          Emailer.issue_invoice(
            recruiter_subscription,
            conn.assigns[:user],
            accounting_email
          )
        end

        conn
        |> put_flash(:info, gettext("Recruiter subscription created successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/recruiter_subscriptions/new")

      {:error, changeset} ->
        has_valid_coupons = has_valid_coupons(conn.assigns[:user])

        recruiter_packages = get_recruiter_packages(conn.assigns[:user])

        render(conn, "new.html",
          changeset: changeset,
          recruiter_packages: recruiter_packages,
          has_valid_coupons: has_valid_coupons
        )
    end
  end

  # def delete(conn, %{"id" => id}) do
  #   recruiter_subscription = Repo.get!(RecruiterSubscription, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(recruiter_subscription)

  #   conn
  #   |> put_flash(:info, gettext("Recruiter subscription deleted successfully."))
  #   |> redirect(to: user_recruiter_subscription_path(conn, :index, conn.assigns[:user]))
  # end

  defp maybe_redeem_coupon(%{coupon_code: nil}), do: :ok

  defp maybe_redeem_coupon(recruiter_subscription) do
    redeemed_coupon =
      Vutuv.Repo.one(
        Ecto.Query.from(c in Vutuv.Recruiting.Coupon,
          where: c.code == ^recruiter_subscription.coupon_code,
          where: c.valid == true,
          limit: 1
        )
      )

    if redeemed_coupon do
      changeset = Coupon.changeset(redeemed_coupon, %{valid: false})
      Vutuv.Repo.update(changeset)

      if redeemed_coupon.percentage == 100 do
        today = Date.utc_today()

        RecruiterSubscription.changeset(recruiter_subscription, %{
          paid: true,
          paid_on: today
        })
        |> Repo.update()
      end
    end
  end

  defp get_recruiter_packages(user) do
    today = Date.utc_today()

    # All which are valid today and don't need a coupon
    recruiter_packages =
      Vutuv.Repo.all(
        from(r in Vutuv.Recruiting.RecruiterPackage,
          where: r.locale_id == ^Locale.locale_id(user.locale),
          where: r.only_with_coupon == false,
          where: r.offer_begins <= ^today,
          where: r.offer_ends >= ^today
        )
      )

    Enum.uniq(List.flatten(recruiter_packages ++ recruiter_packages_available_with_coupon(user)))
  end

  defp has_valid_coupons(user) do
    Enum.any?(recruiter_packages_available_with_coupon(user))
  end

  defp recruiter_packages_available_with_coupon(user) do
    today = Date.utc_today()

    coupons =
      Vutuv.Repo.all(
        from(c in Vutuv.Recruiting.Coupon,
          where: c.user_id == ^user.id,
          where: c.ends_on >= ^today,
          select: c.recruiter_package_id
        )
      )

    Vutuv.Repo.all(
      from(r in Vutuv.Recruiting.RecruiterPackage,
        where: r.locale_id == ^Locale.locale_id(user.locale),
        where: r.id in ^coupons,
        where: r.offer_begins <= ^today,
        where: r.offer_ends >= ^today
      )
    )
  end
end
