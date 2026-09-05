defmodule VutuvWeb.FeedFilterLabelCssTest do
  use ExUnit.Case, async: true

  # The filter button on the phone's feed control row says its word beside the
  # date and gives it up to the waiting-posts pill, which is a quote and needs
  # the width more. *Which* of the two it is, the server decides and
  # `feed_calendar_test.exs` proves. What only the stylesheet can answer is how
  # the word leaves: collapsed and faded over exactly the crossfade beside it,
  # never removed — a word that blinks out while the date underneath is still
  # fading is two movements where the reader should see one.
  #
  # A static source check in the spirit of `hover_reveal_css_test` and
  # `rail_drag_css_test`: it cannot measure a browser, but it holds the shape.

  @css Path.expand("../../assets/css/components.css", __DIR__)
  @feed Path.expand("../../lib/vutuv_web/live/post_live/feed.ex", __DIR__)

  # The whole block, from its first rule to the next commented one — the same
  # slice `hover_reveal_css_test` takes, and for its reason: ending at a neighbour
  # named by class puts whatever gets written between the two inside it.
  defp block do
    [_, rest] = String.split(File.read!(@css), "\n.feed-filter {", parts: 2)
    [body, _] = String.split(rest, "\n/*", parts: 2)
    body
  end

  # One rule's declarations. The leading newline matters: every selector here is
  # also the tail of a longer one, or indented inside a media query.
  defp rule(css, selector) do
    [_, rest] = String.split(css, "\n" <> selector <> " {", parts: 2)
    [body, _] = String.split(rest, "}", parts: 2)
    body
  end

  test "the word collapses and fades, it does not disappear" do
    label = rule(File.read!(@css), ".feed-filter--tight .feed-filter__label")

    # `display: none` would take the word out in one frame, and the date it
    # uncovers is centred in the slot — it would jump sideways in the middle of
    # its own fade. It would also drop the button's own text from the
    # accessibility tree, leaving the `aria-label` alone to name it.
    refute label =~ "display",
           "a word that vanishes in one frame jumps the date sideways mid-crossfade"

    assert label =~ "max-width: 0", "the width is what the pill is being handed"
    assert label =~ "opacity: 0", "and it fades rather than being clipped away"
  end

  test "it runs exactly as long as the crossfade it happens during" do
    css = File.read!(@css)

    [[_, word]] = Regex.scan(~r/max-width (\d+)ms/, rule(css, ".feed-filter__label"))

    [[_, date]] =
      Regex.scan(~r/opacity (\d+)ms/, rule(css, ".feed-cal-slot > .feed-cal-slot__cal"))

    assert word == date,
           "the word's collapse and the date's fade are one movement, so one duration"
  end

  test "the reader who asked for no motion gets the swap without it" do
    body = block()

    assert body =~ "@media (prefers-reduced-motion: reduce)",
           "every animation in this file has this escape, and this one is a width"

    assert body =~ "transition: none"
  end

  test "the classes styled here are the ones the feed puts on the button" do
    # Comments first, or this passes on the prose: `feed.ex` explains each of
    # these classes by name, so a `class=` somebody deleted would still be
    # "found" in the paragraph above it. `feed_seam_class_availability_test`
    # learned the same lesson about `bg-brand-200`.
    markup = String.replace(File.read!(@feed), ~r/<%!--.*?--%>/s, "")

    for class <- ~w(feed-filter feed-filter__label feed-filter--tight) do
      # A whole token in a class list, between a quote and a space either side:
      # a bare substring match would let `feed-filter` be answered by
      # `feed-filter--tight`, which is the half that can go missing.
      assert markup =~ ~r/(?<=["\s])#{Regex.escape(class)}(?=["\s])/,
             "#{class} is styled in components.css but nothing in the feed wears it"
    end
  end
end
