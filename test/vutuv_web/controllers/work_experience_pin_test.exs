defmodule VutuvWeb.WorkExperiencePinTest do
  @moduledoc """
  The profile-job-title chooser (issue #833): the owner pins which work
  experience supplies the `Title @ Organization` line on their profile, and the
  choice flows to the header + meta description. Clearing it falls back to the
  automatic heuristic, and only the owner may set it.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.User

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # The heuristic leads with the open-ended `current` role; `past` is the one
    # the member will pin instead.
    current =
      insert(:work_experience,
        user: user,
        title: "Current Role",
        organization: "NowCo",
        start_month: 3,
        start_year: 2021,
        end_month: nil,
        end_year: nil
      )

    past =
      insert(:work_experience,
        user: user,
        title: "Past Role",
        organization: "ThenCo",
        start_month: 1,
        start_year: 2015,
        end_month: 12,
        end_year: 2018
      )

    %{conn: conn, user: user, current: current, past: past}
  end

  defp meta_description(html) do
    [_, description] = Regex.run(~r/<meta name="description" content="([^"]*)"/, html)
    description
  end

  test "by default the header leads with the heuristic pick", %{conn: conn, user: user} do
    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Current Role @ NowCo"
  end

  test "the owner pins a role and the profile header follows", ctx do
    %{conn: conn, user: user, past: past} = ctx

    conn = put(conn, ~p"/settings/work_experiences/#{past}/pin")
    assert redirected_to(conn) == ~p"/settings/work_experiences"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "at the top of your profile"

    assert Repo.get!(User, user.id).profile_work_experience_id == past.id

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Past Role @ ThenCo"
    refute meta_description(html) =~ "Current Role"
  end

  test "a pinned role outside the 3 most recent by date still leads the header", ctx do
    %{conn: conn, user: user, past: past} = ctx

    # Four fresher roles push `past` (ended 2018) out of any date-ordered
    # top-3 window; the pin must still win on the profile header, exactly as
    # it does in the agent docs and the vCard (they resolve from the full
    # id-ordered list — the header must not resolve from a truncated one).
    for year <- 2019..2022 do
      insert(:work_experience,
        user: user,
        title: "Filler #{year}",
        organization: "FillCo",
        start_month: 1,
        start_year: year,
        end_month: 12,
        end_year: year
      )
    end

    conn = put(conn, ~p"/settings/work_experiences/#{past}/pin")

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Past Role @ ThenCo"
  end

  test "clearing the pin falls back to the automatic heuristic", ctx do
    %{conn: conn, user: user, past: past} = ctx

    conn = put(conn, ~p"/settings/work_experiences/#{past}/pin")
    assert Repo.get!(User, user.id).profile_work_experience_id == past.id

    conn = delete(conn, ~p"/settings/work_experiences/#{past}/pin")
    assert redirected_to(conn) == ~p"/settings/work_experiences"
    assert is_nil(Repo.get!(User, user.id).profile_work_experience_id)

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Current Role @ NowCo"
  end

  test "the /settings editor offers the chooser to the owner", ctx do
    %{conn: conn, past: past, current: current} = ctx

    html = conn |> get(~p"/settings/work_experiences") |> html_response(200)

    # A "Show at top of profile" pin link per role while nothing is pinned yet,
    # and no revert control (there is nothing to revert from).
    assert html =~ ~p"/settings/work_experiences/#{past}/pin"
    assert html =~ ~p"/settings/work_experiences/#{current}/pin"
    assert html =~ "Show at top of profile"
    # The automatic-mode explainer names what the heuristic currently resolves
    # to, so "automatic" doesn't read as "nothing" (issue #883).
    assert html =~ "picked automatically"
    assert html =~ "Current Role @ NowCo"
    refute html =~ "Choose automatically instead"
  end

  test "with a role pinned the editor names it and offers a clear revert to automatic", ctx do
    %{conn: conn, user: user, past: past} = ctx

    conn = put(conn, ~p"/settings/work_experiences/#{past}/pin")
    assert Repo.get!(User, user.id).profile_work_experience_id == past.id

    html = conn |> get(~p"/settings/work_experiences") |> html_response(200)

    # The explainer states which role leads the profile top, and the single
    # always-visible "Choose automatically instead" link replaces the old
    # cryptic per-row "Use automatic" (issue #883).
    assert html =~ "Past Role @ ThenCo shows at the top of your profile"
    assert html =~ "Choose automatically instead"
    assert html =~ "Shown at the top of your profile"
    refute html =~ "picked automatically"
  end

  test "the public page never shows the chooser", %{user: user, current: current} do
    # The public /:slug page is a pure showcase; the chooser lives only on the
    # /settings editor.
    html = build_conn() |> get(~p"/#{user}/work_experiences") |> html_response(200)
    refute html =~ ~p"/settings/work_experiences/#{current}/pin"
    refute html =~ "picked automatically"
    refute html =~ "Show at top of profile"
  end

  test "a logged-out request cannot pin", %{user: user, past: past} do
    # /settings is login-required, so an anonymous pin is turned away first.
    conn = put(build_conn(), ~p"/settings/work_experiences/#{past}/pin")
    assert redirected_to(conn) == "/"
    assert is_nil(Repo.get!(User, user.id).profile_work_experience_id)
  end

  # The German UI must not become an English island: the chooser's copy is
  # translated. Runtime Gettext lookups (not the macro) so extract ignores them.
  test "the chooser copy is translated into German" do
    backend = VutuvWeb.Gettext
    Gettext.put_locale(backend, "de")

    assert Gettext.gettext(backend, "Show at top of profile") == "Oben im Profil anzeigen"

    assert Gettext.gettext(backend, "Choose automatically instead") ==
             "Stattdessen automatisch wählen"

    assert Gettext.gettext(backend, "Shown at the top of your profile") ==
             "Wird oben in Ihrem Profil angezeigt"

    assert Gettext.gettext(backend, "This job title now shows at the top of your profile.") ==
             "Dieser Jobtitel wird jetzt oben in Ihrem Profil angezeigt."
  end
end
