defmodule VutuvWeb.Admin.DiscountCodeControllerTest do
  @moduledoc """
  The ad discount codes at `/admin/ads/discounts`, and the two ways an admin
  finds them: a tile on the dashboard and a link on the ad review page.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Ads
  alias Vutuv.Ads.Discounts

  defp make_code(admin, attrs \\ %{}) do
    {:ok, code} =
      Discounts.create_code(
        admin,
        Map.merge(%{"percent_off" => 20, "expires_on" => in_days(30)}, attrs)
      )

    code
  end

  defp in_days(n), do: Ads.today() |> Date.add(n) |> Date.to_iso8601()

  # The changeset refuses a day that has passed, so an expired code is made by
  # letting a live one age.
  defp expire(code),
    do: Repo.update!(Ecto.Changeset.change(code, expires_on: Date.add(Ads.today(), -1)))

  describe "finding the page" do
    test "the admin dashboard carries a tile into it, counting the live codes", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      make_code(admin)
      expire(make_code(admin))

      html = conn |> get(~p"/admin") |> html_response(200)

      assert html =~ ~s(id="admin-ad-discounts-link")
      assert html =~ ~p"/admin/ads/discounts"
      # The expired one is left out: a code nobody can redeem is not one an
      # admin has out.
      assert html =~ "1 code is valid right now."
    end

    test "the ad review page links it", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      html = conn |> get(~p"/admin/ads") |> html_response(200)

      assert html =~ ~p"/admin/ads/discounts"
    end
  end

  describe "index" do
    test "lists a code with what it takes off", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      code = make_code(admin, %{"note" => "Messe, Oktober"})

      html = conn |> get(~p"/admin/ads/discounts") |> html_response(200)

      assert html =~ code.id
      assert html =~ "20 %"
      assert html =~ "Messe, Oktober"
    end

    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert conn |> get(~p"/admin/ads/discounts") |> html_response(403)
    end
  end
end
