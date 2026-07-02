defmodule VutuvWeb.EducationControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.Profiles.Education

  test "show all educations", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/#{user}/educations")
    assert html_response(conn, 200) =~ "html"
  end

  test "redirect when creating a valid education", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/#{user}/educations", %{
        "education" => %{"school" => "Acme University", "degree" => "BSc"}
      })

    assert redirected_to(conn) == ~p"/#{user}/educations"
    assert Repo.get_by(Education, school: "Acme University", user_id: user.id)
  end

  test "return 422 when creating an education with no school", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = post(conn, ~p"/#{user}/educations", %{"education" => %{"degree" => "BSc"}})
    assert html_response(conn, 422) =~ ~p"/#{user}/educations"
  end

  test "redirect when updating an education", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    education = insert(:education, user: user)

    conn =
      put(conn, ~p"/#{user}/educations/#{education}", %{
        "education" => %{"school" => "New School"}
      })

    # Changing the school regenerates the slug (like a work experience), so the
    # redirect points at the reloaded record, not the pre-update struct.
    updated = Repo.get(Education, education.id)
    assert redirected_to(conn) == ~p"/#{user}/educations/#{updated}"
    assert updated.school == "New School"
  end

  test "redirect when deleting an education", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    education = insert(:education, user: user)
    conn = delete(conn, ~p"/#{user}/educations/#{education}")
    assert redirected_to(conn) == ~p"/#{user}/educations"
    refute Repo.get(Education, education.id)
  end

  test "a member cannot edit another member's education", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    other = insert(:user)
    education = insert(:education, user: other)

    # ResolveOwnedSlug scopes to the logged-in owner, so a foreign slug 404s.
    conn = get(conn, ~p"/#{other}/educations/#{education}/edit")
    assert conn.status == 404
  end

  test "the section index is served as Markdown and JSON too", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)
    insert(:education, user: user, school: "Public University", degree: "PhD")

    assert get(build_conn(), ~p"/#{user}/educations" <> ".md").resp_body =~ "Public University"

    json = Jason.decode!(get(build_conn(), ~p"/#{user}/educations" <> ".json").resp_body)
    assert json["type"] == "educations"
  end
end
