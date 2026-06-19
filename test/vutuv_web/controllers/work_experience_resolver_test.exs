defmodule VutuvWeb.WorkExperienceResolverTest do
  use VutuvWeb.ConnCase, async: true

  # `WorkExperienceController.resolve_slug` loads the work experience scoped to
  # the *path user's* collection before every member action. Two things must
  # hold and are easy to regress when the resolver is extracted into a shared
  # plug:
  #
  #   1. an unknown slug renders a clean 404 and *halts* (no fall-through into
  #      the action with a nil assign), and
  #   2. the scoping is to the path user: another user's work-experience slug
  #      must NOT resolve under this user, it 404s.
  #
  # The collection actions (:index, :new) carry no `:id`, so the resolver must
  # pass through there.

  describe "show on an unknown work-experience slug" do
    test "returns a clean 404 instead of falling through", %{conn: conn} do
      user = insert_activated_user()
      conn = get(conn, ~p"/#{user}/work_experiences/does-not-exist")
      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "owner-scoping" do
    test "another user's work-experience slug does not resolve under this user", %{conn: conn} do
      owner = insert_activated_user()
      other = insert_activated_user()
      foreign = insert(:work_experience, user: other)

      conn = get(conn, ~p"/#{owner}/work_experiences/#{foreign}")
      assert conn.status == 404
      assert conn.halted
    end

    test "the user's own work experience resolves and renders", %{conn: conn} do
      user = insert_activated_user()
      own = insert(:work_experience, user: user)

      conn = get(conn, ~p"/#{user}/work_experiences/#{own}")
      assert conn.status == 200
    end
  end

  describe "legacy entries without a slug" do
    # Imported work experiences can carry a NULL slug. `Phoenix.Param` used to
    # raise on those, which 500ed the whole profile page of the affected user.
    # They fall back to the id as their URL param instead.

    test "the profile page renders and links the entry by id", %{conn: conn} do
      user = insert_activated_user()
      job = insert(:work_experience, user: user, slug: nil, title: "Pionier")

      conn = get(conn, ~p"/#{user}")

      assert html_response(conn, 200) =~ "/#{user.username}/work_experiences/#{job.id}"
    end

    test "the show page resolves via the id", %{conn: conn} do
      user = insert_activated_user()
      job = insert(:work_experience, user: user, slug: nil, title: "Pionier")

      conn = get(conn, ~p"/#{user}/work_experiences/#{job}")

      assert html_response(conn, 200) =~ "Pionier"
    end

    test "an id param never resolves a foreign user's entry", %{conn: conn} do
      owner = insert_activated_user()
      other = insert_activated_user()
      foreign = insert(:work_experience, user: other, slug: nil)

      conn = get(conn, ~p"/#{owner}/work_experiences/#{foreign}")
      assert conn.status == 404
    end
  end

  describe "index (no id param)" do
    test "passes through cleanly and renders the listing", %{conn: conn} do
      user = insert_activated_user()
      conn = get(conn, ~p"/#{user}/work_experiences")
      assert conn.status == 200
    end
  end
end
