defmodule VutuvWeb.PublicationControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.Profiles.Publication

  @params %{
    "title" => "A Methodology for the Emulation of Architecture",
    "authors" => "Carberry, J., Doe, J.",
    "publisher" => "Journal of Psychoceramics",
    "published_year" => "2012",
    "published_month" => "4",
    "url" => "10.5555/12345680",
    "description" => "The *seminal* paper."
  }

  test "the public index lists a member's publications, newest first", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)
    insert(:publication, user: user, title: "Older paper", published_year: 2010)

    insert(:publication,
      user: user,
      title: "Newer paper",
      published_year: 2020,
      publisher: "Nature"
    )

    html = build_conn() |> get(~p"/#{user}/publications") |> html_response(200)
    assert html =~ "Newer paper"
    assert html =~ "Nature · 2020"
    # Newest first: the 2020 paper is rendered before the 2010 one.
    {newer, _} = :binary.match(html, "Newer paper")
    {older, _} = :binary.match(html, "Older paper")
    assert newer < older
  end

  test "the entry page shows every fact, and its agent formats carry them", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)

    publication =
      insert(:publication,
        user: user,
        title: "On Bridges",
        authors: "Gradient, G.",
        publisher: "Span Review",
        published_year: 2019,
        url: "https://doi.org/10.5555/bridges",
        description: "Load *distribution* in long spans."
      )

    html = build_conn() |> get(~p"/#{user}/publications/#{publication}") |> html_response(200)
    assert html =~ "On Bridges"
    assert html =~ "Gradient, G."
    assert html =~ "Span Review"
    assert html =~ "2019"
    assert html =~ "https://doi.org/10.5555/bridges"
    assert html =~ "<em>distribution</em>"

    json =
      build_conn()
      |> get(~p"/#{user}/publications/#{publication}" <> ".json")
      |> json_response(200)

    assert json["type"] == "publication"
    assert json["entry"]["title"] == "On Bridges"
    assert json["entry"]["published"] == "2019"
    assert json["entry"]["url"] == "https://doi.org/10.5555/bridges"

    md = build_conn() |> get(~p"/#{user}/publications.md") |> response(200)
    assert md =~ "On Bridges"
    assert md =~ "Span Review"
  end

  test "the form and the list read in German", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert(:publication, user: user, title: "Brückenbau", published_year: 2019)

    form =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/settings/publications/new")
      |> html_response(200)

    assert form =~ "Publikation hinzufügen"
    assert form =~ "Erschienen in"
    assert form =~ "Die Adresse des Artikels oder nur seine DOI, z. B. 10.1000/xyz123"

    list =
      build_conn()
      |> put_req_header("accept-language", "de-DE,de")
      |> get(~p"/#{user}/publications")
      |> html_response(200)

    assert list =~ "Publikationen von"
  end

  test "creating a publication stores it, resolves the DOI and redirects", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn = post(conn, ~p"/settings/publications", %{"publication" => @params})

    assert redirected_to(conn) == ~p"/settings/publications"
    publication = Repo.get_by!(Publication, user_id: user.id)
    assert publication.title == @params["title"]
    assert publication.url == "https://doi.org/10.5555/12345680"
    assert publication.published_year == 2012
    assert publication.published_month == 4
  end

  test "the new form posts to the route that exists", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    html = conn |> get(~p"/settings/publications/new") |> html_response(200)
    assert html =~ ~s(action="#{~p"/settings/publications"}")
  end

  test "a title-less publication is refused with 422", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    conn = post(conn, ~p"/settings/publications", %{"publication" => %{"publisher" => "Nature"}})
    assert html_response(conn, 422) =~ ~p"/settings/publications"
  end

  test "the owner edits and deletes, a stranger reaches neither", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    publication = insert(:publication, user: user, title: "Draft")

    conn =
      put(conn, ~p"/settings/publications/#{publication}", %{
        "publication" => %{"title" => "Final"}
      })

    assert redirected_to(conn) == ~p"/settings/publications"
    assert Repo.reload(publication).title == "Final"

    stranger = insert_activated_user()
    stranger_publication = insert(:publication, user: stranger, title: "Theirs")

    # ResolveOwnedSlug answers a clean 404 for a row that is not the member's.
    assert conn
           |> get(~p"/settings/publications/#{stranger_publication}/edit")
           |> response(404)

    conn = delete(conn, ~p"/settings/publications/#{Repo.reload(publication)}")
    assert redirected_to(conn) == ~p"/settings/publications"
    refute Repo.reload(publication)
  end

  test "the profile card lists publications and links to the section", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)
    insert(:publication, user: user, title: "Card paper", published_year: 2021)

    html = build_conn() |> get(~p"/#{user}") |> html_response(200)
    assert html =~ "profile-publications"
    assert html =~ "Card paper"
    assert html =~ ~p"/#{user}/publications"
  end
end
