defmodule VutuvWeb.CompanyPeopleTest do
  @moduledoc """
  The company page's People section (issue #931): members whose linked work
  experience is at the company appear, current members first, past members
  tagged "Former", under the member-directory privacy gate. Load-more appends
  the next page over the socket.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp path(company), do: ~p"/companies/#{company.slug}"

  test "lists a current member with their written title and a profile link", %{conn: conn} do
    company = insert(:company, name: "Verified Co")
    member = insert(:activated_user, first_name: "Cara", last_name: "Current", username: "cara")

    insert(:work_experience,
      user: member,
      company: company,
      title: "Lead Engineer",
      end_year: nil
    )

    html = conn |> get(path(company)) |> html_response(200)

    assert html =~ "Cara Current"
    assert html =~ "Lead Engineer"
    assert html =~ ~s(href="/cara")
  end

  test "hides a member who opted out of public listing", %{conn: conn} do
    company = insert(:company)
    hidden = insert(:activated_user, first_name: "Hidden", last_name: "Person", noindex?: true)
    insert(:work_experience, user: hidden, company: company, title: "Secret Role", end_year: nil)

    html = conn |> get(path(company)) |> html_response(200)

    refute html =~ "Hidden Person"
    refute html =~ "Secret Role"
  end

  test "tags a past member as Former", %{conn: conn} do
    company = insert(:company)
    past = insert(:activated_user, first_name: "Percy", last_name: "Past", username: "percy")

    insert(:work_experience,
      user: past,
      company: company,
      title: "Old Role",
      start_year: 2015,
      end_year: 2019
    )

    html = conn |> get(path(company)) |> html_response(200)

    assert html =~ "Percy Past"
    assert html =~ "Former"
  end

  test "load-more appends the next page of people", %{conn: conn} do
    company = insert(:company)

    for i <- 1..30 do
      user = insert(:activated_user, last_name: "Member#{String.pad_leading("#{i}", 2, "0")}")
      insert(:work_experience, user: user, company: company, title: "Dev", end_year: nil)
    end

    {:ok, view, html} = live(conn, path(company))

    # First page shows the per-page cap and a Load more control.
    assert html =~ "Member01"
    assert has_element?(view, "#load-more")

    view |> element("#load-more") |> render_click()

    # A later member only present after appending the second page.
    assert has_element?(view, "#company-people", "Member30")
    refute has_element?(view, "#load-more")
  end
end
