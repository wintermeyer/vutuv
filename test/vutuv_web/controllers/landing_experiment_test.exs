defmodule VutuvWeb.LandingExperimentTest do
  @moduledoc """
  The landing-page headline split test end to end: which headline a visitor
  gets, that it stays put for them, and that each of the three counters is
  bumped exactly once at the right moment.

  The attribution chain is the fragile part — the variant has to survive the
  sign-up POST *and* the PIN round trip, both of which renew the session — so
  the confirmation tests walk the real registration flow rather than poking
  the context directly.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Experiments

  @stube "stube"
  @knapp "knapp"

  defp totals(variant) do
    %{totals: totals} = Experiments.report()
    Enum.find(totals, &(&1.variant == variant))
  end

  defp total_views do
    %{totals: totals} = Experiments.report()
    Enum.reduce(totals, 0, &(&1.views + &2))
  end

  defp session_variant(conn), do: Plug.Conn.get_session(conn, :landing_variant)

  # A visitor who has never been here: an empty session, like the ConnCase
  # fixture but usable more than once in a test.
  defp fresh_conn, do: build_conn() |> init_test_session(%{})

  # vutuv is a German site, so the German render is the one that matters most.
  defp german(conn), do: put_req_header(conn, "accept-language", "de-DE,de;q=0.9")

  defp quote_snippet(@knapp), do: "LinkedIn is annoying. vutuv is not."
  defp quote_snippet(@stube), do: "Tired of LinkedIn? Then come on in"

  defp registration_attrs do
    n = System.unique_integer([:positive])

    %{
      "emails" => %{"0" => %{"value" => "landing#{n}@example.com"}},
      "first_name" => "Landing#{n}",
      "tag_list" => @registration_tags
    }
  end

  describe "which headline a visitor sees" do
    test "the assigned variant decides the quote", %{conn: conn} do
      warm = conn |> init_test_session(landing_variant: @stube) |> get(~p"/")
      dry = build_conn() |> init_test_session(landing_variant: @knapp) |> get(~p"/")

      assert html_response(warm, 200) =~ "Tired of LinkedIn? Then come on in"
      assert html_response(dry, 200) =~ "LinkedIn is annoying. vutuv is not."
    end

    test "both quotes are translated, so no German visitor meets an English one", %{conn: conn} do
      warm = conn |> init_test_session(landing_variant: @stube) |> german() |> get(~p"/")
      dry = fresh_conn() |> init_test_session(landing_variant: @knapp) |> german() |> get(~p"/")

      assert html_response(warm, 200) =~ "Genervt von LinkedIn? Dann herein in die gute Stube."
      assert html_response(dry, 200) =~ "LinkedIn nervt. vutuv nicht."
    end

    test "a first-time visitor is given one of the two and keeps it", %{conn: conn} do
      conn = get(conn, ~p"/")
      variant = session_variant(conn)

      assert Experiments.landing_variant?(variant)

      # Same session, same headline: the quote must not flicker on a reload.
      again = get(recycle(conn), ~p"/")
      assert session_variant(again) == variant
    end

    test "a session carrying nonsense is given a real variant instead", %{conn: conn} do
      conn = conn |> init_test_session(landing_variant: "smuggled") |> get(~p"/")

      assert Experiments.landing_variant?(session_variant(conn))
      assert html_response(conn, 200) =~ "LinkedIn"
    end
  end

  describe "counting" do
    test "one view per session, not per page load", %{conn: conn} do
      conn = get(conn, ~p"/")
      variant = session_variant(conn)
      assert totals(variant).views == 1

      # A reload is the same visitor reading on, not a second view.
      recycle(conn) |> get(~p"/")
      assert totals(variant).views == 1

      # A visitor with no session of their own is.
      get(fresh_conn(), ~p"/")
      assert total_views() == 2
    end

    test "a sign-up counts for the headline that visitor was shown", %{conn: conn} do
      conn =
        conn
        |> init_test_session(landing_variant: @knapp)
        |> get(~p"/")
        |> recycle()
        |> post(~p"/new_registration", user: registration_attrs())

      assert html_response(conn, 200) =~ "PIN"
      assert totals(@knapp).signups == 1
      assert totals(@stube).signups == 0
    end

    test "the confirming PIN counts a confirmation for the same headline", %{conn: conn} do
      conn =
        conn
        |> init_test_session(landing_variant: @knapp)
        |> get(~p"/")
        |> recycle()
        |> post(~p"/new_registration", user: registration_attrs())

      conn =
        submit_with_csrf(conn, ~p"/login", %{
          "session" => %{"pin" => sent_pin(), "context" => "registration"}
        })

      assert redirected_to(conn) == ~p"/system/welcome"
      assert totals(@knapp).confirmations == 1
      # Counted once, then forgotten, so a later login cannot count a second.
      refute session_variant(conn)
    end

    test "an ordinary login counts nothing, even from a visitor who saw the page", %{conn: conn} do
      fresh_conn() |> init_test_session(landing_variant: @stube) |> get(~p"/")

      {_conn, _user} = create_and_login_user(conn)

      assert totals(@stube).confirmations == 0
      assert totals(@stube).signups == 0
    end

    test "a counter that cannot be written never takes the start page down", %{conn: conn} do
      # The blue/green deploy migrates before the new release serves, so a
      # missing table is not the realistic failure — a busy pool or a lock is.
      # Taking the table away is simply the cheapest way to make the write
      # raise. The DDL rides this test's own sandbox transaction and is rolled
      # back with it.
      Repo.query!("ALTER TABLE experiment_stats RENAME TO experiment_stats_gone")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "LinkedIn"
      # Still assigned, so the visitor's headline does not flicker either.
      assert Experiments.landing_variant?(session_variant(conn |> get(~p"/")))
    end

    test "a failed sign-up keeps the headline and counts no second view", %{conn: conn} do
      conn = get(conn, ~p"/")
      variant = session_variant(conn)

      conn =
        conn
        |> recycle()
        |> post(~p"/new_registration", user: %{"first_name" => "No Email"})

      assert html_response(conn, 422) =~ quote_snippet(variant)
      assert totals(variant).views == 1
      assert totals(variant).signups == 0
    end
  end
end
