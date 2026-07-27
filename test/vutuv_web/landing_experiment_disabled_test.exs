defmodule VutuvWeb.LandingExperimentDisabledTest do
  @moduledoc """
  The off switch for the landing-page headline split test
  (`config :vutuv, :landing_headline_experiment`, read through
  `Vutuv.Experiments.enabled?/0`) — what an installation that has no interest
  in our marketing copy gets.

  async: false, like `VutuvWeb.AdsDisabledTest`: these flip a global
  application env the SQL sandbox does not roll back, so they must not run
  beside a test that reads the same flag.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Experiments

  setup do
    # The default (config/config.exs) is on; flip it off for the test and put
    # it back so the rest of the suite exercises the real thing.
    Application.put_env(:vutuv, :landing_headline_experiment, false)
    on_exit(fn -> Application.put_env(:vutuv, :landing_headline_experiment, true) end)
  end

  test "Experiments.enabled?/0 follows the config switch" do
    refute Experiments.enabled?()

    Application.put_env(:vutuv, :landing_headline_experiment, true)
    assert Experiments.enabled?()
  end

  test "every visitor gets the default headline", %{conn: conn} do
    variants =
      for _ <- 1..20 do
        build_conn()
        |> init_test_session(%{})
        |> get(~p"/")
        |> Plug.Conn.get_session(:landing_variant)
      end

    assert Enum.uniq(variants) == [Experiments.default_landing_variant()]
    assert html_response(get(conn, ~p"/"), 200) =~ "Tired of LinkedIn? Then come on in"
  end

  test "nothing is counted", %{conn: conn} do
    conn = get(conn, ~p"/")

    conn
    |> recycle()
    |> post(~p"/new_registration",
      user: %{
        "emails" => %{"0" => %{"value" => "disabled-experiment@example.com"}},
        "first_name" => "Nobody",
        "tag_list" => @registration_tags
      }
    )

    %{totals: totals} = Experiments.report()

    assert Enum.all?(totals, &(&1.views == 0 and &1.signups == 0))
  end
end
