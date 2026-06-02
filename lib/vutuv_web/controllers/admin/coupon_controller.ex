defmodule VutuvWeb.Admin.CouponController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)

  alias Vutuv.Recruiting.Coupon

  def index(conn, _params) do
    coupons = Repo.all(Coupon)
    render(conn, "index.html", coupons: coupons)
  end

  def new(conn, _params) do
    changeset = Coupon.changeset(%Coupon{code: Coupon.random_code()})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"coupon" => coupon_params}) do
    changeset = Coupon.changeset(%Coupon{}, coupon_params)

    case Repo.insert(changeset) do
      {:ok, _coupon} ->
        conn
        |> put_flash(:info, gettext("Coupon created successfully."))
        |> redirect(to: ~p"/admin/coupons")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    coupon = Repo.get!(Coupon, id)
    render(conn, "show.html", coupon: coupon)
  end

  def edit(conn, %{"id" => id}) do
    coupon = Repo.get!(Coupon, id)
    changeset = Coupon.changeset(coupon)
    render(conn, "edit.html", coupon: coupon, changeset: changeset)
  end

  def update(conn, %{"id" => id, "coupon" => coupon_params}) do
    coupon = Repo.get!(Coupon, id)
    changeset = Coupon.changeset(coupon, coupon_params)

    case Repo.update(changeset) do
      {:ok, coupon} ->
        conn
        |> put_flash(:info, gettext("Coupon updated successfully."))
        |> redirect(to: ~p"/admin/coupons/#{coupon}")

      {:error, changeset} ->
        render(conn, "edit.html", coupon: coupon, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    coupon = Repo.get!(Coupon, id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(coupon)

    conn
    |> put_flash(:info, gettext("Coupon deleted successfully."))
    |> redirect(to: ~p"/admin/coupons")
  end
end
