defmodule VutuvWeb.SinglePhotoFitTest do
  @moduledoc """
  How a lone photo is fitted into a feed card (issue #1104).

  The rule is "show it whole unless the shape is extreme", and the whole value
  of it sits at the boundary — so this walks the shapes cameras and phones
  actually produce and asserts none of them is cropped, then checks that the
  one deliberate extreme that is still cropped stays cropped.

  **Only tall photos are cropped.** A wide one is never cut: a wide frame at
  column width is merely flat, and there the crop cost content without buying
  anything back — the 1572×424 screenshot that made this rule fall over lost
  the right third of its text in the feed while the permalink showed it whole.
  A tall one is the case that keeps its crop, because there the card really
  does turn into a scroll the reader has to get past.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Posts.PostImage
  alias VutuvWeb.PostComponents

  defp photo(width, height), do: %PostImage{width: width, height: height, token: "t"}
  defp fit(width, height), do: PostComponents.feed_photo_fit(photo(width, height))

  describe "ordinary shapes are shown whole" do
    # Every one of these is a shape somebody's camera or phone hands them.
    # If a future tweak to the envelope starts cropping one, that is the
    # regression this file exists to catch.
    for {label, w, h} <- [
          {"4:3 compact camera", 4032, 3024},
          {"3:4 portrait of the same", 3024, 4032},
          {"3:2 full frame", 6000, 4000},
          {"2:3 portrait full frame", 4000, 6000},
          {"16:9 wide", 1920, 1080},
          {"9:16 phone portrait", 1080, 1920},
          {"1:1 square", 2000, 2000},
          {"5:4 medium format", 2500, 2000},
          {"4:5 portrait crop", 2000, 2500}
        ] do
      test "#{label} is not cropped" do
        assert PostComponents.feed_photo_fit(photo(unquote(w), unquote(h))) == :whole
      end
    end
  end

  describe "a wide photo is never cropped" do
    # The shape of the post that reopened this: a screenshot of a news teaser
    # card, whose right-hand third (the headline and the teaser text) was cut
    # away by the old 2:1 crop.
    test "a wide screenshot keeps every pixel of its width" do
      assert fit(1572, 424) == :whole
    end

    test "even a stitched panorama is shown whole, only flat" do
      assert fit(10_000, 1000) == :whole
      assert fit(6000, 1500) == :whole
    end
  end

  describe "a tall photo is cropped to an ordinary frame" do
    test "a tall tower becomes a 3:4 frame instead of a card you scroll past" do
      assert fit(1000, 10_000) == {:crop, "3 / 4"}
      assert fit(1500, 6000) == {:crop, "3 / 4"}
    end

    test "the crop frame is itself an ordinary shape" do
      {:crop, aspect} = fit(1000, 10_000)
      [w, h] = aspect |> String.split(" / ") |> Enum.map(&String.to_integer/1)
      assert w / h <= 2.0
      assert w / h >= 0.5
    end
  end

  describe "the boundary" do
    test "1:2 is still ordinary; just past it is not" do
      assert fit(1000, 2000) == :whole
      assert fit(1000, 2100) == {:crop, "3 / 4"}
    end

    test "there is no upper boundary left to trip over" do
      assert fit(2000, 1000) == :whole
      assert fit(2100, 1000) == :whole
    end

    test "a photo with no stored dimensions is shown whole, never cropped blind" do
      assert PostComponents.feed_photo_fit(%PostImage{}) == :whole
    end
  end
end
