defmodule Vutuv.Uploads.CropTest do
  @moduledoc """
  The user-chosen crop rectangle: parsing the `"x,y,w,h"` wire/DB string into
  clamped fractions, and applying it to a (rotated) image before the resize
  pipeline. A malformed or absent crop is always "no crop", never an error —
  a bad param must not fail an upload.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Uploads.Crop

  describe "parse/1" do
    test "parses a well-formed crop string into fractions" do
      assert Crop.parse("0.1,0.2,0.5,0.4") == {0.1, 0.2, 0.5, 0.4}
    end

    test "treats nil, empty and malformed input as no crop" do
      assert Crop.parse(nil) == nil
      assert Crop.parse("") == nil
      assert Crop.parse("not a crop") == nil
      assert Crop.parse("0.1,0.2,0.5") == nil
      assert Crop.parse("0.1,0.2,0.5,0.4,0.9") == nil
      assert Crop.parse("a,b,c,d") == nil
      assert Crop.parse(%{}) == nil
    end

    test "rejects out-of-range fractions" do
      assert Crop.parse("-0.1,0,0.5,0.5") == nil
      assert Crop.parse("0,0,1.5,0.5") == nil
    end

    test "trims a size that would overrun the right/bottom edge" do
      # x=0.8, w=0.5 would reach 1.3; the width is clamped to 0.2.
      assert {x, y, w, h} = Crop.parse("0.8,0,0.5,1")
      assert_in_delta x, 0.8, 1.0e-9
      assert_in_delta y, 0.0, 1.0e-9
      assert_in_delta w, 0.2, 1.0e-9
      assert_in_delta h, 1.0, 1.0e-9
    end

    test "a full-frame crop is treated as no crop (it would be a no-op)" do
      assert Crop.parse("0,0,1,1") == nil
    end

    test "a zero-area crop is no crop" do
      assert Crop.parse("0.2,0.2,0,0.5") == nil
      assert Crop.parse("0.2,0.2,0.5,0") == nil
    end
  end

  describe "normalize/1" do
    test "re-serialises a valid crop to a canonical string" do
      assert Crop.normalize("0.1,0.2,0.5,0.4") == "0.1000,0.2000,0.5000,0.4000"
    end

    test "is nil for an invalid or no-op crop" do
      assert Crop.normalize(nil) == nil
      assert Crop.normalize("garbage") == nil
      assert Crop.normalize("0,0,1,1") == nil
    end

    test "round-trips through parse" do
      assert "0.2500,0.2500,0.5000,0.5000" = normalized = Crop.normalize("0.25,0.25,0.5,0.5")
      assert Crop.parse(normalized) == {0.25, 0.25, 0.5, 0.5}
    end
  end

  describe "apply_to/2" do
    test "returns the image unchanged when there is no crop" do
      {:ok, img} = Image.new(100, 80, color: [10, 20, 30])
      assert {:ok, same} = Crop.apply_to(img, nil)
      assert {Image.width(same), Image.height(same)} == {100, 80}
    end

    test "crops to the fractional rectangle's pixel dimensions" do
      {:ok, img} = Image.new(100, 100, color: [10, 20, 30])
      assert {:ok, cropped} = Crop.apply_to(img, {0.25, 0.25, 0.5, 0.5})
      assert {Image.width(cropped), Image.height(cropped)} == {50, 50}
    end

    test "extracts the correct region (position, not just size)" do
      # Black 100x100 canvas with a white 20x20 square at the top-left (10,10).
      {:ok, base} = Image.new(100, 100, color: [0, 0, 0])
      {:ok, mark} = Image.new(20, 20, color: [255, 255, 255])
      {:ok, img} = Image.compose(base, mark, x: 10, y: 10)

      # Cropping the top-left quadrant keeps the white square... (compose adds
      # an alpha channel, so read the red channel off whatever bands come back).
      {:ok, top_left} = Crop.apply_to(img, {0.0, 0.0, 0.4, 0.4})
      assert [r | _] = Image.get_pixel!(top_left, 10, 10)
      assert r > 200

      # ...cropping the bottom-right quadrant is all black.
      {:ok, bottom_right} = Crop.apply_to(img, {0.6, 0.6, 0.4, 0.4})
      assert bottom_right |> Image.get_pixel!(10, 10) |> Enum.take(3) == [0, 0, 0]
    end
  end
end
