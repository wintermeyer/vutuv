defmodule VutuvWeb.FeedRailHelpers do
  @moduledoc """
  Driving the `/feed` rail's cards from a LiveView test.

  Imported where it is needed rather than into every `VutuvWeb.ConnCase`: a
  handful of test files reach for it, and that case template's `quote` block is
  already at the length Credo will refuse.

  It exists because the same fifteen lines sat in three test files and one
  latent selector bug then had to be fixed in all three — which is what the
  selector below is about (see `folded?/2`).
  """

  import Phoenix.LiveViewTest

  @doc """
  Whether the rail card `key` is folded to its heading.

  **The probe names the fold button.** A card ships collapsed with its body out
  of the DOM, and the caret's own `aria-expanded` is what says so — but once the
  card is open, the branch triangles inside it carry that attribute too, so a
  selector that takes any of them reads an open card as folded, and a helper
  built on it folds the card again on the next call.
  """
  def folded?(live, key) do
    has_element?(live, ~s(#rail-#{key} button[phx-click="rail-collapse"][aria-expanded="false"]))
  end

  @doc """
  Gets `live` to where the card `key` can be used, and returns `live`.

  For a rail card that is folded to its heading, that means unfolding it. For
  the three that left the rail — sources, words and hidden tags now live in one
  panel behind `#feed-filter-row` — it means opening that panel on the right
  tab. Callers say which card they want to use, not where it currently lives,
  so the move cost the test files nothing.
  """
  def unfold(live, key) when key in ["sources", "words", "hidden_tags"] do
    open_filter_panel(live, if(key == "sources", do: "sources", else: "words"))
  end

  def unfold(live, key) do
    if folded?(live, key) do
      live |> element(~s(#rail-#{key} button[phx-click="rail-collapse"])) |> render_click()
    end

    live
  end

  @doc """
  Opens the feed's filter panel and returns `live`.

  The way in changes with the member: a row once something is hidden, a quiet
  line while nothing is — so the helper takes whichever is on the page rather
  than making every caller know which member it built.
  """
  def open_filter_panel(live, tab \\ "words") do
    if has_element?(live, "#filter-panel") do
      live |> element("#filter-tab-#{tab}") |> render_click()
    else
      entry =
        if has_element?(live, "#feed-filter-row"),
          do: "#feed-filter-row",
          else: "#feed-filter-link"

      live |> element(entry) |> render_click()
      # The row opens on the words half; a caller after the sources half says so.
      if tab != "words", do: live |> element("#filter-tab-#{tab}") |> render_click()
    end

    live
  end
end
