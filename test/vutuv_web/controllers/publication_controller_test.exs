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

  # The editor's ORCID offer with the import switched off (the test default):
  # neither the button nor the hint, so an intranet never dangles a dead link.
  test "the editor offers no ORCID import while the switch is off", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert(:social_media_account, provider: "ORCID", value: "0000-0002-1825-0097", user: user)

    html = conn |> get(~p"/settings/publications") |> html_response(200)
    refute html =~ "orcid-import-offer"
    refute html =~ "orcid-import-hint"

    conn = get(conn, ~p"/settings/publications/orcid")
    assert redirected_to(conn) == ~p"/settings/publications"
  end
end

defmodule VutuvWeb.PublicationOrcidImportTest do
  @moduledoc """
  "Import from ORCID" (issue #2383) end to end: the offer on the editor, the
  preview and the POST that writes the picks.

  Not async: the switch (`:import_orcid_works`) and the Req seam
  (`:orcid_req_options`) live in the application env.
  """
  use VutuvWeb.ConnCase

  import Ecto.Query
  import Vutuv.Factory

  alias Vutuv.Profiles.Publication

  @id "0000-0002-1825-0097"

  setup do
    Application.put_env(:vutuv, :import_orcid_works, true)
    on_exit(fn -> Application.put_env(:vutuv, :import_orcid_works, false) end)
    :ok
  end

  defp serve_works(titles) do
    groups =
      for {_title, put_code} <- Enum.with_index(titles, 1),
          do: %{"work-summary" => [%{"put-code" => put_code}]}

    bulk =
      for {title, put_code} <- Enum.with_index(titles, 1) do
        %{
          "work" => %{
            "put-code" => put_code,
            "title" => %{"title" => %{"value" => title}},
            "journal-title" => %{"value" => "Span Review"},
            "type" => "journal-article",
            "publication-date" => %{"year" => %{"value" => "2019"}}
          }
        }
      end

    Application.put_env(:vutuv, :orcid_req_options,
      plug: fn conn ->
        body =
          if String.ends_with?(conn.request_path, "/works"),
            do: %{"group" => groups},
            else: %{"bulk" => bulk}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :orcid_req_options) end)
  end

  test "the editor hints at the iD, then offers the import once it is listed", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings/publications") |> html_response(200)
    assert html =~ "orcid-import-hint"
    refute html =~ "orcid-import-offer"

    insert(:social_media_account, provider: "ORCID", value: @id, user: user)

    html = conn |> recycle() |> get(~p"/settings/publications") |> html_response(200)
    assert html =~ "orcid-import-offer"
    assert html =~ ~p"/settings/publications/orcid"
  end

  test "without an iD the preview sends the member to the social-media form", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    conn = get(conn, ~p"/settings/publications/orcid")
    assert redirected_to(conn) == ~p"/settings/social_media_accounts/new"
  end

  test "the preview lists the record's works, the POST imports the ticked ones", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert(:social_media_account, provider: "ORCID", value: @id, user: user)
    insert(:publication, user: user, title: "On Bridges", slug: "on-bridges")
    serve_works(["On Bridges", "Load Paths", "Unticked"])

    html = conn |> get(~p"/settings/publications/orcid") |> html_response(200)
    assert html =~ "Load Paths · Span Review · 2019 · Journal article"
    assert html =~ "already on your profile"
    assert html =~ ~s(action="#{~p"/settings/publications/orcid"}")

    # The hidden field as the browser would submit it: the attribute value
    # with its HTML escapes undone.
    [payload] = Regex.run(~r/name="payload" value="([^"]+)"/, html, capture: :all_but_first)
    decoded_payload = payload |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&")

    ids =
      Regex.scan(~r/name="selected\[\]" value="([^"]+)"/, html, capture: :all_but_first)
      |> List.flatten()

    assert length(ids) == 3
    # Tick the first two: the duplicate and "Load Paths".
    conn =
      post(conn, ~p"/settings/publications/orcid", %{
        "payload" => decoded_payload,
        "selected" => Enum.take(ids, 2)
      })

    assert redirected_to(conn) == ~p"/settings/publications"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "1 publication imported"

    titles =
      Repo.all(from(p in Publication, where: p.user_id == ^user.id, select: p.title))
      |> Enum.sort()

    assert titles == ["Load Paths", "On Bridges"]
  end

  test "an unreachable ORCID lands back on the editor with a sentence, not a 500", %{
    conn: conn
  } do
    {conn, user} = create_and_login_user(conn)
    insert(:social_media_account, provider: "ORCID", value: @id, user: user)

    Application.put_env(:vutuv, :orcid_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 503, "") end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :orcid_req_options) end)

    conn = get(conn, ~p"/settings/publications/orcid")
    assert redirected_to(conn) == ~p"/settings/publications"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not answer"
  end
end
