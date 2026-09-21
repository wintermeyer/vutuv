defmodule VutuvWeb.SearchOrganizationsLiveTest do
  @moduledoc """
  The search page with organizations: a fifth scope chip, "All" as a preview
  of every kind with a link into each, pages inside a kind, and an
  organization's people reached from its row.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.SearchHelpers

  defp rows(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  test "the scope row carries an Organizations chip", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search?q=anything")

    assert has_element?(view, "#search-scope-organizations", "Organizations")
  end

  test "All previews three people and links to the full list", %{conn: conn} do
    for n <- 1..4, do: searchable_user("Quendolin", "Tester#{n}")

    {:ok, view, _html} = live(conn, ~p"/search?q=quendolin")

    assert rows(view, "#search-people-exact > li") == 3
    assert has_element?(view, ~s(#search-people-all[href="/search?q=quendolin&scope=people"]))
  end

  test "the People scope lists every match on pages", %{conn: conn} do
    for n <- 1..26, do: searchable_user("Pagella", "Nummer#{n}")

    {:ok, view, _html} = live(conn, ~p"/search?q=pagella&scope=people")
    assert rows(view, "#search-people-exact > li") == 25
    assert has_element?(view, "#search-pager a", "2")

    {:ok, view, _html} = live(conn, ~p"/search?q=pagella&scope=people&page=2")
    assert rows(view, "#search-people-exact > li") == 1
  end

  test "a member found through their CV shows the entry that matched", %{conn: conn} do
    member = insert(:activated_user, first_name: "Wiebke", last_name: "Anders")

    insert(:work_experience,
      user: member,
      organization: "Pelikan Werft",
      title: "Werftleiterin",
      start_year: 2015
    )

    {:ok, view, _html} = live(conn, ~p"/search?q=pelikan")

    assert has_element?(view, "#search-people-exact li", "Wiebke Anders")
    assert has_element?(view, "#search-people-exact li", "Werftleiterin @ Pelikan Werft")
  end

  test "a name and an employer in one query find the person at that employer", %{conn: conn} do
    member = insert(:activated_user, first_name: "Lukas", last_name: "Kaiser")
    insert(:work_experience, user: member, organization: "Quarzwerk AG", title: "Entwickler")

    {:ok, view, _html} = live(conn, ~p"/search?q=lukas quarzwerk")

    assert has_element?(view, "#search-people-exact li", "Lukas Kaiser")
    assert has_element?(view, "#search-people-exact li", "Entwickler @ Quarzwerk AG")
  end

  test "an organization row counts its people and narrows the list to them", %{conn: conn} do
    org = insert(:organization, name: "Lindwurm Maschinenbau")
    now = insert(:activated_user, first_name: "Ilvy", last_name: "Sandhagen")
    before = insert(:activated_user, first_name: "Bruno", last_name: "Kessler")
    insert(:work_experience, user: now, organization_id: org.id, title: "Konstrukteurin")

    insert(:work_experience,
      user: before,
      organization_id: org.id,
      title: "Azubi",
      start_year: 2001,
      end_year: 2004
    )

    {:ok, view, _html} = live(conn, ~p"/search?q=lindwurm&scope=organizations")

    assert has_element?(view, "#search-organizations li", "Lindwurm Maschinenbau")

    view |> element("#search-org-people-#{org.slug}") |> render_click()
    assert_patch(view, ~p"/search?org=#{org.slug}")

    assert has_element?(view, "#search-org-filter", "Lindwurm Maschinenbau")
    assert has_element?(view, "#search-org-current + ul li", "Ilvy Sandhagen")
    assert has_element?(view, "#search-org-former + ul li", "Bruno Kessler")
    assert has_element?(view, ~s(#search-scope-tags[aria-disabled="true"]))
  end

  test "a name narrows the people at an organization, and the filter can be removed", %{
    conn: conn
  } do
    org = insert(:organization, name: "Lindwurm Werke")
    wanted = insert(:activated_user, first_name: "Ilvy", last_name: "Sandhagen")
    other = insert(:activated_user, first_name: "Bruno", last_name: "Kessler")
    insert(:work_experience, user: wanted, organization_id: org.id)
    insert(:work_experience, user: other, organization_id: org.id)

    {:ok, view, _html} = live(conn, ~p"/search?org=#{org.slug}&q=sandha")

    assert has_element?(view, "#search-org-people", "Ilvy Sandhagen")
    refute has_element?(view, "#search-org-people", "Bruno Kessler")

    view |> element("#search-org-filter-remove") |> render_click()
    assert_patch(view, ~p"/search?q=sandha")
    refute has_element?(view, "#search-org-filter")
  end

  test "an organization that is not public is no filter", %{conn: conn} do
    pending = insert(:organization, status: "pending")

    {:ok, view, _html} = live(conn, ~p"/search?org=#{pending.slug}&q=anything")

    refute has_element?(view, "#search-org-filter")
    refute has_element?(view, "#search-org-people")
  end

  test "the Posts scope pages through every match", %{conn: conn} do
    author = insert(:activated_user)

    for n <- 1..26 do
      Vutuv.PostsHelpers.create_post!(author, %{body: "Holunderblütensirup Rezept #{n}"})
    end

    {:ok, view, _html} = live(conn, ~p"/search?q=holunderblütensirup")
    assert rows(view, "#search-posts li") == 3
    assert has_element?(view, "#search-posts-all", "26")

    {:ok, view, _html} = live(conn, ~p"/search?q=holunderblütensirup&scope=posts&page=2")
    assert rows(view, "#search-posts li") == 1
  end

  test "the new labels are German for a German reader", %{conn: conn} do
    org = insert(:organization, name: "Lindwurm Sprachen")
    insert(:work_experience, user: insert(:activated_user), organization_id: org.id)
    conn = put_req_header(conn, "accept-language", "de-DE,de")

    {:ok, view, _html} = live(conn, ~p"/search?q=lindwurm")
    assert has_element?(view, "#search-scope-organizations", "Organisationen")
    assert has_element?(view, "#search-org-people-#{org.slug}", "1 Person")

    {:ok, view, _html} = live(conn, ~p"/search?org=#{org.slug}")
    assert has_element?(view, "#search-org-filter", "Nur bei Lindwurm Sprachen")
    assert has_element?(view, "#search-org-current", "Heute bei Lindwurm Sprachen")
  end
end
