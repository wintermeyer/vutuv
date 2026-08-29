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
  Opens the rail card `key` if it is folded, and returns `live`.

  Two cards ship folded to their heading ("Sources" and "Hide tags"), so their
  bodies are not in the DOM until somebody opens them — which is what a reader
  does before touching a switch, and what a test has to do too.
  """
  def unfold(live, key) do
    if folded?(live, key) do
      live |> element(~s(#rail-#{key} button[phx-click="rail-collapse"])) |> render_click()
    end

    live
  end
end
