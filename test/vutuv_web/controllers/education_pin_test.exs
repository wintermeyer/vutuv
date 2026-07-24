defmodule VutuvWeb.EducationPinTest do
  @moduledoc """
  The profile-headline chooser for education (issue #882): the owner may pin an
  education entry as the "Degree, School" line at the top of their profile,
  instead of a job title, for a student or someone unemployed. The headline is
  EITHER a pinned work experience OR a pinned education, never both, so pinning
  one clears the other. Clearing falls back to the automatic job heuristic, and
  only the owner may pin their own entry.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias VutuvWeb.AgentDocs.ProfileDoc

  @headline "Doctor of Medicine, St. Mary's University"
  # The apostrophe in the school name is HTML-escaped to &#39; in rendered
  # pages, so raw-HTML string assertions match on the part before it; the
  # LiveView `has_element?` text filter and the raw ProfileDoc struct keep the
  # full string.
  @headline_html "Doctor of Medicine, St. Mary"

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # An open-ended role the automatic heuristic leads with while nothing is
    # pinned — so a switch to the pinned education is observable.
    job =
      insert(:work_experience,
        user: user,
        title: "Current Role",
        organization: "NowCo",
        start_month: 3,
        start_year: 2021,
        end_month: nil,
        end_year: nil
      )

    degree =
      insert(:education,
        user: user,
        degree: "Doctor of Medicine",
        school: "St. Mary's University",
        field_of_study: "Medicine"
      )

    school =
      insert(:education,
        user: user,
        degree: nil,
        school: "Old Grammar School",
        kind: "school"
      )

    %{conn: conn, user: user, job: job, degree: degree, school: school}
  end

  defp meta_description(html) do
    [_, description] = Regex.run(~r/<meta name="description" content="([^"]*)"/, html)
    description
  end

  # ── The context: mutual exclusion + authorization ──

  describe "Accounts.pin_profile_education/2 (mutual exclusion + ownership)" do
    test "pinning an education sets the pointer and clears a pinned work experience", ctx do
      %{user: user, job: job, degree: degree} = ctx

      {:ok, user} = Accounts.pin_profile_work_experience(user, job)
      assert user.profile_work_experience_id == job.id

      {:ok, user} = Accounts.pin_profile_education(user, degree)

      assert user.profile_education_id == degree.id
      assert is_nil(user.profile_work_experience_id)
    end

    test "pinning a work experience clears a pinned education", ctx do
      %{user: user, job: job, degree: degree} = ctx

      {:ok, user} = Accounts.pin_profile_education(user, degree)
      assert user.profile_education_id == degree.id

      {:ok, user} = Accounts.pin_profile_work_experience(user, job)

      assert user.profile_work_experience_id == job.id
      assert is_nil(user.profile_education_id)
    end

    test "unpinning clears only the education pointer", ctx do
      %{user: user, degree: degree} = ctx

      {:ok, user} = Accounts.pin_profile_education(user, degree)
      {:ok, user} = Accounts.unpin_profile_education(user)

      assert is_nil(user.profile_education_id)
    end

    test "a member cannot pin another user's education", %{user: user} do
      other = insert_activated_user()
      foreign = insert(:education, user: other, degree: "Foreign Degree", school: "TheirSchool")

      assert {:error, :not_owner} = Accounts.pin_profile_education(user, foreign)
      assert is_nil(Repo.get!(User, user.id).profile_education_id)
    end
  end

  # ── The controller flow ──

  test "by default the header leads with the heuristic job", %{conn: conn, user: user} do
    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Current Role @ NowCo"
    refute meta_description(html) =~ @headline
  end

  test "the owner pins an education and the profile header follows", ctx do
    %{conn: conn, user: user, degree: degree} = ctx

    conn = put(conn, ~p"/settings/educations/#{degree}/pin")
    assert redirected_to(conn) == ~p"/settings/educations"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "at the top of your profile"

    assert Repo.get!(User, user.id).profile_education_id == degree.id

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ @headline_html
    refute meta_description(html) =~ "Current Role"
  end

  test "the connected profile renders the pinned education as the headline line", ctx do
    %{conn: conn, user: user, degree: degree} = ctx

    {:ok, _user} = Accounts.pin_profile_education(user, degree)

    {:ok, view, _html} = live(conn, ~p"/#{user}")

    assert has_element?(view, "#profile-headline", @headline)
    refute has_element?(view, "#profile-headline", "Current Role")
  end

  test "clearing the pin falls back to the automatic job heuristic", ctx do
    %{conn: conn, user: user, degree: degree} = ctx

    conn = put(conn, ~p"/settings/educations/#{degree}/pin")
    assert Repo.get!(User, user.id).profile_education_id == degree.id

    conn = delete(conn, ~p"/settings/educations/#{degree}/pin")
    assert redirected_to(conn) == ~p"/settings/educations"
    assert is_nil(Repo.get!(User, user.id).profile_education_id)

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Current Role @ NowCo"
  end

  test "the /settings editor offers the chooser to the owner", ctx do
    %{conn: conn, degree: degree, school: school} = ctx

    html = conn |> get(~p"/settings/educations") |> html_response(200)

    assert html =~ ~p"/settings/educations/#{degree}/pin"
    assert html =~ ~p"/settings/educations/#{school}/pin"
    assert html =~ "Show at top of profile"
    refute html =~ "Choose automatically instead"
  end

  test "with an education pinned the editor names it and offers a clear revert", ctx do
    %{conn: conn, user: user, degree: degree} = ctx

    conn = put(conn, ~p"/settings/educations/#{degree}/pin")
    assert Repo.get!(User, user.id).profile_education_id == degree.id

    html = conn |> get(~p"/settings/educations") |> html_response(200)

    assert html =~ @headline_html
    assert html =~ "shows at the top of your profile"
    assert html =~ "Choose automatically instead"
    assert html =~ "Shown at the top of your profile"
  end

  test "the public educations page never shows the chooser", %{user: user, degree: degree} do
    html = build_conn() |> get(~p"/#{user}/educations") |> html_response(200)
    refute html =~ ~p"/settings/educations/#{degree}/pin"
    refute html =~ "Show at top of profile"
  end

  test "a logged-out request cannot pin", %{user: user, degree: degree} do
    conn = put(build_conn(), ~p"/settings/educations/#{degree}/pin")
    assert redirected_to(conn) == "/"
    assert is_nil(Repo.get!(User, user.id).profile_education_id)
  end

  # ── Agent docs (ProfileDoc) reflect the pinned education ──

  test "the profile doc's headline reflects a pinned education", ctx do
    %{user: user, degree: degree} = ctx

    {:ok, _user} = Accounts.pin_profile_education(user, degree)

    # Build from a fresh struct, the way the controller passes the plug-resolved
    # user (ProfileDoc.build owns all preloading); the setup user carries a
    # partial user_tags preload that would shadow it.
    doc = ProfileDoc.build(Repo.get!(User, user.id))
    assert doc.work_info == @headline
    assert doc.description == @headline
  end

  # The German UI must stay translated (issue #882 copy). Runtime Gettext lookups
  # so the extractor ignores them.
  test "the chooser copy is translated into German" do
    backend = VutuvWeb.Gettext
    Gettext.put_locale(backend, "de")

    assert Gettext.gettext(backend, "This education now shows at the top of your profile.") ==
             "Diese Ausbildung wird jetzt oben in Ihrem Profil angezeigt."

    assert Gettext.gettext(
             backend,
             "Pick a degree or school below to show it at the top of your profile instead of a job title."
           ) ==
             "Wählen Sie unten einen Abschluss oder eine Schule, um ihn statt eines Jobtitels oben in Ihrem Profil anzuzeigen."
  end
end
