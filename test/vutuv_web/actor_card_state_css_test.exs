defmodule VutuvWeb.ActorCardStateCssTest do
  use ExUnit.Case, async: true

  # The mention card's follow button wears its state as a colour, and the class
  # that colours it is **interpolated** from the state:
  # `RemoteActorCardHTML.state_btn_modifier/1` is
  # `"actor-card__state-btn--#{Follow.display_state(follow)}"`. So no grep
  # connects `Vutuv.Fediverse.Follow`'s three atoms to `components.css`, and
  # nothing fails when they disagree.
  #
  # They disagreed from the day the card shipped (PR #1903) until this test:
  # the stylesheet spelled the accepted state `--following`, so the commonest
  # state of all — the member already follows this account — rendered as an
  # unstyled button in the card's own text colour, in the one place the reader
  # looks to find out where they stand. Every other state was fine, which is
  # why it survived review.
  #
  # A fourth atom in `display_state/1` would ship the same silence, so the
  # check is over the atoms rather than over a list of three names: add a state
  # and this goes red until the colour exists, in both themes.
  #
  # Static source check in the spirit of `dark_mode_css_test.exs` and
  # `mobile_tab_bar_css_test.exs`.

  @follow Path.expand("../../lib/vutuv/fediverse/follow.ex", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  # Comments name selectors; strip them so the assertions only see real rules.
  defp css, do: Regex.replace(~r{/\*.*?\*/}s, File.read!(@components_css), "")

  # The atoms `Follow.display_state/1` can answer, read off its clause heads
  # rather than listed here — a list here would be the second copy this test
  # exists to prevent.
  defp display_states do
    File.read!(@follow)
    |> then(&Regex.scan(~r/def display_state\(.*?\), do: :(\w+)/, &1))
    |> Enum.map(fn [_, state] -> state end)
    |> tap(fn states ->
      assert states != [],
             "No `display_state/1` clauses found in #{@follow}. If it moved, move this test."
    end)
  end

  test "every follow state the card can render has a colour" do
    css = css()

    for state <- display_states() do
      assert css =~ ".actor-card__state-btn--#{state} {",
             """
             `Follow.display_state/1` can answer `:#{state}`, which the card
             renders as `.actor-card__state-btn--#{state}` — and components.css
             has no such rule, so that button paints as unstyled text.
             """
    end
  end

  test "and has one in dark mode too" do
    [_, dark] = String.split(css(), "@media (prefers-color-scheme: dark) {", parts: 2)

    for state <- display_states() do
      assert dark =~ ".actor-card__state-btn--#{state} {",
             "`.actor-card__state-btn--#{state}` has no dark variant in components.css."
    end
  end
end
