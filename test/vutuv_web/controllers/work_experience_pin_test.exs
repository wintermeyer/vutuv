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

    conn = put(conn, ~p"/#{user}/work_experiences/#{past}/pin")
    assert redirected_to(conn) == ~p"/#{user}/work_experiences"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "appears on your profile"

    assert Repo.get!(User, user.id).profile_work_experience_id == past.id

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Past Role @ ThenCo"
    refute meta_description(html) =~ "Current Role"
  end

  test "clearing the pin falls back to the automatic heuristic", ctx do
    %{conn: conn, user: user, past: past} = ctx

    conn = put(conn, ~p"/#{user}/work_experiences/#{past}/pin")
    assert Repo.get!(User, user.id).profile_work_experience_id == past.id

    conn = delete(conn, ~p"/#{user}/work_experiences/#{past}/pin")
    assert redirected_to(conn) == ~p"/#{user}/work_experiences"
    assert is_nil(Repo.get!(User, user.id).profile_work_experience_id)

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert meta_description(html) =~ "Current Role @ NowCo"
  end

  test "the management list offers the chooser to the owner", ctx do
    %{conn: conn, user: user, past: past, current: current} = ctx

    html = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

    # A pin link per role while nothing is pinned yet.
    assert html =~ ~p"/#{user}/work_experiences/#{past}/pin"
    assert html =~ ~p"/#{user}/work_experiences/#{current}/pin"
    assert html =~ "chosen automatically"
  end

  test "a visitor never sees the chooser", %{user: user, current: current} do
    # Logged-out: the management page is public, but the chooser is owner-only.
    html = build_conn() |> get(~p"/#{user}/work_experiences") |> html_response(200)
    refute html =~ ~p"/#{user}/work_experiences/#{current}/pin"
    refute html =~ "chosen automatically"
  end

  test "a logged-out request cannot pin", %{user: user, past: past} do
    conn = put(build_conn(), ~p"/#{user}/work_experiences/#{past}/pin")
    assert conn.status == 403
    assert is_nil(Repo.get!(User, user.id).profile_work_experience_id)
  end

  # The German UI must not become an English island: the chooser's copy is
  # translated. Runtime Gettext lookups (not the macro) so extract ignores them.
  test "the chooser copy is translated into German" do
    backend = VutuvWeb.Gettext
    Gettext.put_locale(backend, "de")

    assert Gettext.gettext(backend, "Show on profile") == "Auf Profil anzeigen"
    assert Gettext.gettext(backend, "Use automatic") == "Automatisch verwenden"
    assert Gettext.gettext(backend, "Shown on your profile") == "Auf Ihrem Profil sichtbar"

    assert Gettext.gettext(backend, "This job title now appears on your profile.") ==
             "Dieser Jobtitel erscheint jetzt auf Ihrem Profil."
  end
end
