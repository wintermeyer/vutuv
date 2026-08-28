defmodule VutuvWeb.OrganizationPeopleTest do
  @moduledoc """
  The organization page's People section (issue #931): members whose linked work
  experience is at the organization appear, current members first, past members
  tagged "Former". Load-more appends the next page over the socket.

  Who may appear is confirmed-and-not-moderation-hidden, and deliberately **not**
  the search-engine opt-out (v7.433.0): a switch about Google must not hide
  somebody from their own employer's page. It buys the row's `rel="nofollow"`.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp path(organization), do: ~p"/organizations/#{organization.slug}"

  test "lists a current member with their written title and a profile link", %{conn: conn} do
    organization = insert(:organization, name: "Verified Co")
    member = insert(:activated_user, first_name: "Cara", last_name: "Current", username: "cara")

    insert(:work_experience,
      user: member,
      organization_page: organization,
      title: "Lead Engineer",
      end_year: nil
    )

    html = conn |> get(path(organization)) |> html_response(200)

    assert html =~ "Cara Current"
    assert html =~ "Lead Engineer"
    assert html =~ ~s(href="/cara")
  end

  test "lists a member who opted out of search engines, rel=nofollow", %{conn: conn} do
    organization = insert(:organization)

    opted_out =
      insert(:activated_user,
        first_name: "Nina",
        last_name: "Noindex",
        username: "nina",
        noindex?: true
      )

    insert(:work_experience,
      user: opted_out,
      organization_page: organization,
      title: "Quiet Role",
      end_year: nil
    )

    html = conn |> get(path(organization)) |> html_response(200)

    # She is on her own employer's page like anybody else. Until v7.433.0 the
    # search-engine switch hid her from it — from colleagues and from herself —
    # while the directory, search and every follower list showed her.
    assert html =~ "Nina Noindex"
    assert html =~ "Quiet Role"

    # What the switch buys instead: crawlers are told not to walk through.
    assert [_link] = nofollow_links(html, "nina")
  end

  test "a member who allows indexing gets no nofollow", %{conn: conn} do
    # The other side of the pair — without it the assertion above passes just as
    # well with `rel="nofollow"` stamped on every row.
    organization = insert(:organization)
    open = insert(:activated_user, first_name: "Otto", last_name: "Open", username: "ottoopen")

    insert(:work_experience,
      user: open,
      organization_page: organization,
      title: "Loud Role",
      end_year: nil
    )

    html = conn |> get(path(organization)) |> html_response(200)

    assert html =~ "Otto Open"
    assert nofollow_links(html, "ottoopen") == []
  end

  test "tags a past member as Former", %{conn: conn} do
    organization = insert(:organization)
    past = insert(:activated_user, first_name: "Percy", last_name: "Past", username: "percy")

    insert(:work_experience,
      user: past,
      organization_page: organization,
      title: "Old Role",
      start_year: 2015,
      end_year: 2019
    )

    html = conn |> get(path(organization)) |> html_response(200)

    assert html =~ "Percy Past"
    assert html =~ "Former"
  end

  test "load-more appends the next page of people", %{conn: conn} do
    organization = insert(:organization)

    for i <- 1..30 do
      user = insert(:activated_user, last_name: "Member#{String.pad_leading("#{i}", 2, "0")}")

      insert(:work_experience,
        user: user,
        organization_page: organization,
        title: "Dev",
        end_year: nil
      )
    end

    {:ok, view, html} = live(conn, path(organization))

    # First page shows the per-page cap and a Load more control.
    assert html =~ "Member01"
    assert has_element?(view, "#load-more")

    view |> element("#load-more") |> render_click()

    # A later member only present after appending the second page.
    assert has_element?(view, "#organization-people", "Member30")
    refute has_element?(view, "#load-more")
  end
end
