defmodule VutuvWeb.SinglePhotoFitTest do
  @moduledoc """
  How a lone photo is fitted into a feed card (issue #1104).

  The rule is "show it whole unless the shape is extreme", and the whole value
  of it sits at the boundary — so this walks the shapes cameras and phones
  actually produce and asserts none of them is cropped, then checks that the
  deliberate extremes still are.
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

  describe "extreme shapes are cropped to an ordinary frame" do
    test "a stitched panorama becomes a 2:1 frame instead of a slit" do
      assert fit(10_000, 1000) == {:crop, "2 / 1"}
      assert fit(6000, 1500) == {:crop, "2 / 1"}
    end

    test "a tall tower becomes a 3:4 frame instead of a card you scroll past" do
      assert fit(1000, 10_000) == {:crop, "3 / 4"}
      assert fit(1500, 6000) == {:crop, "3 / 4"}
    end

    test "the crop frames are themselves ordinary shapes" do
      for {:crop, aspect} <- [fit(10_000, 1000), fit(1000, 10_000)] do
        [w, h] = aspect |> String.split(" / ") |> Enum.map(&String.to_integer/1)
        assert w / h <= 2.0
        assert w / h >= 0.5
      end
    end
  end

  describe "the boundary" do
    test "2:1 and 1:2 are still ordinary; just past them is not" do
      assert fit(2000, 1000) == :whole
      assert fit(1000, 2000) == :whole

      assert fit(2100, 1000) == {:crop, "2 / 1"}
      assert fit(1000, 2100) == {:crop, "3 / 4"}
    end

    test "a photo with no stored dimensions is shown whole, never cropped blind" do
      assert PostComponents.feed_photo_fit(%PostImage{}) == :whole
    end
  end
end
