defmodule VutuvWeb.LanguageControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.Profiles.Language

  test "the public index lists a member's languages", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)
    insert(:language, user: user, language_code: "de", proficiency: "native")

    html = build_conn() |> get(~p"/#{user}/languages") |> html_response(200)
    assert html =~ "German"
    assert html =~ "Native"
  end

  test "the opaque CEFR badge carries a plain-language tooltip (issue #888)", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)
    insert(:language, user: user, language_code: "en", proficiency: "b2")

    html = build_conn() |> get(~p"/#{user}/languages") |> html_response(200)
    # The badge still shows the bare code, now with a `title` gloss so a reader
    # who does not know the CEFR scale learns what "B2" means on hover.
    assert html =~ "B2"
    assert html =~ "title=\"B2 (Upper intermediate)\""
  end

  test "redirect when creating a valid language", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/settings/languages", %{
        "language" => %{"language_code" => "de", "proficiency" => "native"}
      })

    assert redirected_to(conn) == ~p"/settings/languages"
    assert Repo.get_by(Language, language_code: "de", user_id: user.id)
  end

  test "return 422 when creating a language with an unknown code", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/settings/languages", %{
        "language" => %{"language_code" => "xx", "proficiency" => "b2"}
      })

    assert html_response(conn, 422) =~ ~p"/settings/languages"
  end

  test "return 422 when listing the same language twice", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert(:language, user: user, language_code: "en", proficiency: "native")

    conn =
      post(conn, ~p"/settings/languages", %{
        "language" => %{"language_code" => "en", "proficiency" => "b2"}
      })

    assert html_response(conn, 422) =~ ~p"/settings/languages"
  end

  test "redirect when updating a language", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    language = insert(:language, user: user, language_code: "en", proficiency: "b1")

    conn =
      put(conn, ~p"/settings/languages/#{language}", %{
        "language" => %{"proficiency" => "c2"}
      })

    assert redirected_to(conn) == ~p"/settings/languages"
    assert Repo.get(Language, language.id).proficiency == "c2"
  end

  test "redirect when deleting a language", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    language = insert(:language, user: user, language_code: "en", proficiency: "b1")

    conn = delete(conn, ~p"/settings/languages/#{language}")
    assert redirected_to(conn) == ~p"/settings/languages"
    refute Repo.get(Language, language.id)
  end

  test "a member cannot reach another member's language editor", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    other = insert(:user)
    insert(:language, user: other, language_code: "fr", proficiency: "native")

    # ResolveOwnedSlug scopes to the logged-in owner, so a foreign code 404s.
    conn = get(conn, ~p"/settings/languages/fr/edit")
    assert conn.status == 404
  end

  describe "public page vs /settings editor" do
    setup %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:language, user: owner, language_code: "de", proficiency: "native")
      %{conn: conn, owner: owner}
    end

    test "the owner's public page shows the showcase plus the Manage bridge", %{
      conn: conn,
      owner: owner
    } do
      html = conn |> get(~p"/#{owner}/languages") |> html_response(200)

      assert html =~ ~s(class="profile-header__manage")
      assert html =~ ~s(href="#{~p"/settings/languages"}")
      # No owner edit chrome on the public page itself.
      refute html =~ ~p"/settings/languages/new"
      assert html =~ "German"
    end

    test "a visitor sees the same page, minus the Manage bridge", %{owner: owner} do
      html = build_conn() |> get(~p"/#{owner}/languages") |> html_response(200)

      refute html =~ ~s(class="profile-header__manage")
      assert html =~ "German"
    end

    test "the /settings editor carries the owner chrome", %{conn: conn} do
      html = conn |> get(~p"/settings/languages") |> html_response(200)

      assert html =~ "data-settings-shell"
      assert html =~ ~p"/settings/languages/new"
      assert html =~ "German"
    end
  end

  describe "preferred contact language marker (issue #894)" do
    setup do
      owner = insert_activated_user()
      # English first (the member's preference), German native second — order,
      # not proficiency, decides. Positions pin the order deterministically.
      insert(:language, user: owner, language_code: "en", proficiency: "b2", position: 1)
      insert(:language, user: owner, language_code: "de", proficiency: "native", position: 2)
      %{owner: owner}
    end

    test "the public languages page marks the first entry", %{owner: owner} do
      html = build_conn() |> get(~p"/#{owner}/languages") |> html_response(200)
      assert html =~ "Preferred"
    end

    test "the Markdown sibling glosses the first language", %{owner: owner} do
      body = build_conn() |> get("/#{owner.username}/languages.md") |> response(200)
      # The English entry (listed first) carries the gloss; German does not.
      assert body =~ "English: B2 (Preferred contact language)"
      refute body =~ "German: Native (Preferred"
    end

    test "the JSON sibling flags the first language", %{owner: owner} do
      body = build_conn() |> get("/#{owner.username}/languages.json") |> response(200)
      json = Jason.decode!(body)
      [first, second] = json["entries"]
      assert first["code"] == "en" and first["preferred"] == true
      refute Map.has_key?(second, "preferred")
    end

    test "the profile doc marks it too", %{owner: owner} do
      body = build_conn() |> get("/#{owner.username}.json") |> response(200)
      [first | _] = Jason.decode!(body)["languages"]
      assert first["code"] == "en" and first["preferred"] == true
    end
  end

  test "a lone language carries no preferred marker" do
    owner = insert_activated_user()
    insert(:language, user: owner, language_code: "en", proficiency: "b2", position: 1)

    html = build_conn() |> get(~p"/#{owner}/languages") |> html_response(200)
    refute html =~ "Preferred"

    body = build_conn() |> get("/#{owner.username}/languages.md") |> response(200)
    refute body =~ "Preferred contact language"
  end
end
