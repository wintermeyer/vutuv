defmodule VutuvWeb.CouponControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Recruiting.Coupon

  @invalid_attrs %{code: nil, ends_on: nil}

  setup %{conn: conn} do
    {conn, user} = create_and_login_admin(conn)
    {:ok, conn: conn, user: user}
  end

  defp valid_attrs(user) do
    %{
      code: Coupon.random_code(),
      ends_on: Date.utc_today() |> Date.add(30),
      percentage: 10,
      user_id: user.id
    }
  end

  defp create_coupon(user) do
    %Coupon{}
    |> Coupon.changeset(valid_attrs(user))
    |> Repo.insert!()
  end

  test "lists all entries on index", %{conn: conn} do
    conn = get(conn, ~p"/admin/coupons")
    assert html_response(conn, 200) =~ "All coupons"
  end

  test "renders form for new resources", %{conn: conn} do
    conn = get(conn, ~p"/admin/coupons/new")
    assert html_response(conn, 200) =~ "New coupon"
  end

  test "creates resource and redirects when data is valid", %{conn: conn, user: user} do
    attrs = valid_attrs(user)
    conn = post(conn, ~p"/admin/coupons", coupon: attrs)
    assert redirected_to(conn) == ~p"/admin/coupons"
    assert Repo.get_by(Coupon, %{code: attrs.code})
  end

  test "does not create resource and renders errors when data is invalid", %{conn: conn} do
    conn = post(conn, ~p"/admin/coupons", coupon: @invalid_attrs)
    assert html_response(conn, 200) =~ "New coupon"
  end

  test "shows chosen resource", %{conn: conn, user: user} do
    coupon = create_coupon(user)
    conn = get(conn, ~p"/admin/coupons/#{coupon}")
    assert html_response(conn, 200) =~ "Show coupon"
  end

  test "renders page not found when id is nonexistent", %{conn: conn} do
    assert_error_sent(404, fn ->
      get(conn, ~p"/admin/coupons/#{-1}")
    end)
  end

  test "renders form for editing chosen resource", %{conn: conn, user: user} do
    coupon = create_coupon(user)
    conn = get(conn, ~p"/admin/coupons/#{coupon}/edit")
    assert html_response(conn, 200) =~ "Edit coupon"
  end

  test "updates chosen resource and redirects when data is valid", %{conn: conn, user: user} do
    coupon = create_coupon(user)
    attrs = valid_attrs(user)
    conn = put(conn, ~p"/admin/coupons/#{coupon}", coupon: attrs)
    assert redirected_to(conn) == ~p"/admin/coupons/#{coupon}"
    assert Repo.get_by(Coupon, %{code: attrs.code})
  end

  test "does not update chosen resource and renders errors when data is invalid", %{
    conn: conn,
    user: user
  } do
    coupon = create_coupon(user)
    conn = put(conn, ~p"/admin/coupons/#{coupon}", coupon: @invalid_attrs)
    assert html_response(conn, 200) =~ "Edit coupon"
  end

  test "deletes chosen resource", %{conn: conn, user: user} do
    coupon = create_coupon(user)
    conn = delete(conn, ~p"/admin/coupons/#{coupon}")
    assert redirected_to(conn) == ~p"/admin/coupons"
    refute Repo.get(Coupon, coupon.id)
  end
end
