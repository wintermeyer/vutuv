defmodule VutuvWeb.EmploymentStatusTest do
  @moduledoc """
  The employment-status feature (issue #870): the job-availability badge on
  the profile header and the select that sets it on the Basics & photos form.
  """

  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  describe "the profile badge" do
    test "shows 'Looking for a job' for a member who is looking", %{conn: conn} do
      user = insert_activated_user(employment_status: "looking")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Looking for a job"
      assert html =~ ~s(data-employment-status="looking")
    end

    test "shows 'Open to offers' for a member who is open", %{conn: conn} do
      user = insert_activated_user(employment_status: "open")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Open to offers"
      assert html =~ ~s(data-employment-status="open")
    end

    test "renders the badge above the tagline, right below the name", %{conn: conn} do
      user = insert_activated_user(employment_status: "looking", headline: "Some tagline here")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      # The pill sits on its own line under the name, ahead of the tagline text.
      badge_at = :binary.match(html, "data-employment-status") |> elem(0)
      tagline_at = :binary.match(html, "Some tagline here") |> elem(0)
      assert badge_at < tagline_at
    end

    test "shows no badge for a member who has not set a status", %{conn: conn} do
      user = insert_activated_user(employment_status: nil, headline: "Just here")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "data-employment-status"
      refute html =~ "Looking for a job"
      refute html =~ "Open to offers"
    end
  end

  describe "the Basics & photos form" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "renders the employment-status select with the three choices", %{conn: conn} do
      html = conn |> get(~p"/settings/profile") |> html_response(200)

      assert html =~ ~s(name="user[employment_status]")
      assert html =~ "Not open to work"
      assert html =~ "Open to offers"
      assert html =~ "Looking for a job"
    end

    test "saving 'looking' persists the status", %{conn: conn, user: user} do
      conn = put(conn, ~p"/settings/profile", user: %{"employment_status" => "looking"})

      assert redirected_to(conn) == ~p"/#{user}"
      assert Repo.get!(User, user.id).employment_status == "looking"
    end

    test "the saved status then renders as a badge on the profile", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"employment_status" => "open"})

      html = conn |> get(~p"/#{user}") |> html_response(200)
      assert html =~ "Open to offers"
    end

    test "choosing 'Not open to work' clears a previously set status", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user(user, %{"employment_status" => "looking"})
      assert user.employment_status == "looking"

      put(conn, ~p"/settings/profile", user: %{"employment_status" => ""})

      assert Repo.get!(User, user.id).employment_status == nil
    end
  end
end
