defmodule VutuvWeb.InvestorMinimumTest do
  @moduledoc """
  The investor page's minimum-investment block under a changed
  `:investor_minimum` / `:investor_currency`, which is what an installation
  that raises nothing, or raises in another currency, ships.

  **`async: false`, and its own file.** `Application.put_env/3` is global and
  the SQL sandbox does not roll it back, so for as long as this holds the key
  down every other test reading it sees the changed value. Both keys are read
  in exactly one place, `VutuvWeb.AgentDocs.InvestorsDoc.minimum/0`, so the
  blast radius is `/system/investors` and its agent formats — check that again
  before adding a second reader.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.PeopleHistory.Snapshot
  alias Vutuv.Repo

  setup do
    Repo.delete_all(Snapshot)
    :ok
  end

  # Capture with fetch_env/2, not get_env/2: `nil` from get_env means both
  # "absent" and "holds nil", so a naive restore can write nil back as a real
  # value and every later reader gets it instead of the function's default.
  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  test "a zero minimum drops the whole block rather than saying nothing costs", %{conn: conn} do
    put_config(:investor_minimum, 0)

    html = conn |> get(~p"/system/investors") |> html_response(200)

    refute html =~ "Minimum investment"
    # Anchored on the sentence, not on the word "Euro": the speed claim beside
    # it names "37 European and American brands", and that contains it.
    refute html =~ "An investment conversation makes sense"
    refute html =~ "300.000"
    refute html =~ "300,000"
    # The rest of the page is untouched: an installation not raising anything
    # still wants to say what it is.
    assert html =~ "A professional network that works without an account"
  end

  test "a zero minimum leaves the agent formats without one too", %{conn: conn} do
    put_config(:investor_minimum, 0)

    json = conn |> get(~p"/system/investors" <> ".json") |> json_response(200)
    markdown = conn |> get(~p"/system/investors" <> ".md") |> response(200)

    refute json["minimum"]
    refute json["minimum_reason"]
    refute markdown =~ "{amount}"
    refute markdown =~ "Minimum investment"
  end

  test "another currency keeps its own symbol", %{conn: conn} do
    put_config(:investor_minimum, 250_000)
    put_config(:investor_currency, "USD")

    html = conn |> get(~p"/system/investors") |> html_response(200)

    assert html =~ "250,000 US dollars"
  end

  test "a currency with no name here keeps its ISO code", %{conn: conn} do
    # A currency with no name here falls back to `Vutuv.Salary`, which answers
    # with the ISO code — correct in the same place ("250,000 SEK").
    put_config(:investor_minimum, 250_000)
    put_config(:investor_currency, "SEK")

    html = conn |> get(~p"/system/investors") |> html_response(200)

    assert html =~ "250,000 SEK"
  end

  test "an empty currency falls back instead of leaving a trailing space", %{conn: conn} do
    # `INVESTOR_CURRENCY=""` is a configured value, so a `||` default never sees
    # it and the amount would end in a non-breaking space and nothing.
    put_config(:investor_minimum, 250_000)
    put_config(:investor_currency, "")

    html = conn |> get(~p"/system/investors") |> html_response(200)

    assert html =~ "250,000 Euro"
  end
end
