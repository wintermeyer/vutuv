defmodule VutuvWeb.Admin.ExperimentControllerTest do
  @moduledoc """
  The admin readout of the landing-page headline test. The page's job is to
  keep an admin from calling the race too early, so the verdict line is what
  these tests hold onto.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Experiments

  describe "GET /admin/experiments" do
    test "a logged-in non-admin is refused", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      assert html_response(get(conn, ~p"/admin/experiments"), 403)
    end

    test "an admin sees both variants with their quotes", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      html = conn |> get(~p"/admin/experiments") |> html_response(200)

      assert html =~ "Landing page headline test"
      assert html =~ "LinkedIn is annoying. vutuv is not."
      assert html =~ "Tired of LinkedIn? Then come on in"
      assert html =~ ~s(data-variant="stube")
      assert html =~ ~s(data-variant="knapp")
    end

    test "an empty test says so instead of showing a 0 % failure", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      html = conn |> get(~p"/admin/experiments") |> html_response(200)

      assert html =~ "Too early to say"
      assert html =~ "Nothing counted yet."
      # No views yet is a dash, not a measured zero.
      assert html =~ "–"
    end

    test "a decided test names its winner", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      for _ <- 1..70, do: Experiments.record("stube", :signups)
      for _ <- 1..30, do: Experiments.record("knapp", :signups)

      html = conn |> get(~p"/admin/experiments") |> html_response(200)

      assert html =~ "Invitation wins"
      # The confirmation half has its own, still-undecided verdict.
      assert html =~ "Too early to say"
    end

    test "the day table lists what was counted", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      Experiments.record("knapp", :views)

      html = conn |> get(~p"/admin/experiments") |> html_response(200)

      assert html =~ Date.to_iso8601(Vutuv.BerlinTime.today())
      refute html =~ "Nothing counted yet."
    end
  end
end
