defmodule VutuvWeb.QualificationControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.Profiles.Qualification

  test "the public index lists a member's certificates", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)
    insert(:qualification, user: user, name: "AWS Solutions Architect", issuer: "Amazon")

    html = build_conn() |> get(~p"/#{user}/qualifications") |> html_response(200)
    assert html =~ "AWS Solutions Architect"
    assert html =~ "Amazon"
  end

  test "redirect when creating a valid qualification", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/settings/qualifications", %{
        "qualification" => %{
          "name" => "Certified Scrum Master",
          "kind" => "certification",
          "issuer" => "Scrum Alliance"
        }
      })

    assert redirected_to(conn) == ~p"/settings/qualifications"
    assert Repo.get_by(Qualification, name: "Certified Scrum Master", user_id: user.id)
  end

  test "return 422 when creating a qualification without a name", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/settings/qualifications", %{
        "qualification" => %{"name" => "", "kind" => "certification"}
      })

    assert html_response(conn, 422) =~ ~p"/settings/qualifications"
  end

  test "redirect when updating a qualification", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    qualification = insert(:qualification, user: user, name: "Old name")

    conn =
      put(conn, ~p"/settings/qualifications/#{qualification}", %{
        "qualification" => %{"name" => "New name"}
      })

    assert redirected_to(conn) == ~p"/settings/qualifications"
    assert Repo.get(Qualification, qualification.id).name == "New name"
  end

  test "redirect when deleting a qualification", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    qualification = insert(:qualification, user: user)

    conn = delete(conn, ~p"/settings/qualifications/#{qualification}")
    assert redirected_to(conn) == ~p"/settings/qualifications"
    refute Repo.get(Qualification, qualification.id)
  end

  test "a member cannot reach another member's qualification editor", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    other = insert(:user)
    qualification = insert(:qualification, user: other)

    # resolve_qualification scopes to the logged-in owner, so a foreign id 404s.
    conn = get(conn, ~p"/settings/qualifications/#{qualification}/edit")
    assert conn.status == 404
  end

  test "a non-UUID entry id 404s instead of raising", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)

    assert build_conn() |> get(~p"/#{user}/qualifications/not-a-uuid") |> Map.get(:status) == 404
  end

  describe "expired credentials" do
    setup %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:qualification, user: owner, name: "Current cert", expires_year: nil)

      insert(:qualification,
        user: owner,
        name: "Lapsed cert",
        awarded_year: 2015,
        expires_year: 2018
      )

      %{conn: conn, owner: owner}
    end

    test "a visitor's public page hides expired credentials", %{owner: owner} do
      html = build_conn() |> get(~p"/#{owner}/qualifications") |> html_response(200)

      assert html =~ "Current cert"
      refute html =~ "Lapsed cert"
    end

    test "the owner's /settings editor shows expired credentials", %{conn: conn} do
      html = conn |> get(~p"/settings/qualifications") |> html_response(200)

      assert html =~ "Current cert"
      assert html =~ "Lapsed cert"
      assert html =~ "data-settings-shell"
      assert html =~ ~p"/settings/qualifications/new"
    end
  end

  describe "public page vs /settings editor" do
    setup %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:qualification, user: owner, name: "AWS Solutions Architect")
      %{conn: conn, owner: owner}
    end

    test "the owner's public page shows the showcase plus the Manage bridge", %{
      conn: conn,
      owner: owner
    } do
      html = conn |> get(~p"/#{owner}/qualifications") |> html_response(200)

      assert html =~ ~s(class="profile-header__manage")
      assert html =~ ~s(href="#{~p"/settings/qualifications"}")
      refute html =~ ~p"/settings/qualifications/new"
      assert html =~ "AWS Solutions Architect"
    end

    test "a visitor sees the same page, minus the Manage bridge", %{owner: owner} do
      html = build_conn() |> get(~p"/#{owner}/qualifications") |> html_response(200)

      refute html =~ ~s(class="profile-header__manage")
      assert html =~ "AWS Solutions Architect"
    end
  end
end
