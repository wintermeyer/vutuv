defmodule VutuvWeb.RecruiterPackageControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Recruiting.RecruiterPackage

  @invalid_attrs %{name: nil, description: nil}

  setup %{conn: conn} do
    {conn, user} = create_and_login_admin(conn)
    locale = Repo.get_by!(Vutuv.Accounts.Locale, value: "en")
    {:ok, conn: conn, user: user, locale: locale}
  end

  defp valid_attrs(locale) do
    %{
      name: "Basic Package",
      description: "A basic recruiter package",
      slug: "basic-package",
      locale_id: locale.id,
      price: 9.99,
      currency: "EUR",
      duration_in_months: 1,
      auto_renewal: true,
      offer_begins: Date.utc_today(),
      offer_ends: Date.utc_today() |> Date.add(365),
      max_job_postings: 5,
      only_with_coupon: false
    }
  end

  defp create_recruiter_package(locale) do
    %RecruiterPackage{}
    |> RecruiterPackage.changeset(valid_attrs(locale))
    |> Repo.insert!()
  end

  test "lists all entries on index", %{conn: conn} do
    conn = get(conn, ~p"/admin/recruiter_packages")
    assert html_response(conn, 200) =~ "All recruiter packages"
  end

  test "renders form for new resources", %{conn: conn} do
    conn = get(conn, ~p"/admin/recruiter_packages/new")
    assert html_response(conn, 200) =~ "New recruiter package"
  end

  test "creates resource and redirects when data is valid", %{conn: conn, locale: locale} do
    attrs = valid_attrs(locale)
    conn = post(conn, ~p"/admin/recruiter_packages", recruiter_package: attrs)
    assert redirected_to(conn) == ~p"/admin/recruiter_packages"
    assert Repo.get_by(RecruiterPackage, %{name: attrs.name})
  end

  test "does not create resource and renders errors when data is invalid", %{conn: conn} do
    conn =
      post(conn, ~p"/admin/recruiter_packages", recruiter_package: @invalid_attrs)

    assert html_response(conn, 200) =~ "New recruiter package"
  end

  test "shows chosen resource", %{conn: conn, locale: locale} do
    recruiter_package = create_recruiter_package(locale)
    conn = get(conn, ~p"/admin/recruiter_packages/#{recruiter_package}")
    assert html_response(conn, 200) =~ "Show recruiter package"
  end

  test "renders page not found when id is nonexistent", %{conn: conn} do
    assert_error_sent(404, fn ->
      get(conn, ~p"/admin/recruiter_packages/#{-1}")
    end)
  end

  test "renders form for editing chosen resource", %{conn: conn, locale: locale} do
    recruiter_package = create_recruiter_package(locale)
    conn = get(conn, ~p"/admin/recruiter_packages/#{recruiter_package}/edit")
    assert html_response(conn, 200) =~ "Edit recruiter package"
  end

  test "updates chosen resource and redirects when data is valid", %{conn: conn, locale: locale} do
    recruiter_package = create_recruiter_package(locale)
    attrs = %{valid_attrs(locale) | name: "Updated Package", slug: "updated-package"}

    conn =
      put(conn, ~p"/admin/recruiter_packages/#{recruiter_package}", recruiter_package: attrs)

    assert redirected_to(conn) == ~p"/admin/recruiter_packages/#{recruiter_package}"
    assert Repo.get_by(RecruiterPackage, %{name: "Updated Package"})
  end

  test "does not update chosen resource and renders errors when data is invalid", %{
    conn: conn,
    locale: locale
  } do
    recruiter_package = create_recruiter_package(locale)

    conn =
      put(conn, ~p"/admin/recruiter_packages/#{recruiter_package}",
        recruiter_package: @invalid_attrs
      )

    assert html_response(conn, 200) =~ "Edit recruiter package"
  end

  test "deletes chosen resource", %{conn: conn, locale: locale} do
    recruiter_package = create_recruiter_package(locale)
    conn = delete(conn, ~p"/admin/recruiter_packages/#{recruiter_package}")
    assert redirected_to(conn) == ~p"/admin/recruiter_packages"
    refute Repo.get(RecruiterPackage, recruiter_package.id)
  end
end
