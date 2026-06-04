defmodule VutuvWeb.Admin.CouponController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)

  alias Vutuv.Recruiting.Coupon
  alias VutuvWeb.ControllerHelpers

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

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Coupon created successfully."),
      redirect_to: ~p"/admin/coupons",
      render: "new.html"
    )
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

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Coupon updated successfully."),
      redirect_to: &~p"/admin/coupons/#{&1}",
      render: "edit.html",
      assigns: [coupon: coupon]
    )
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
