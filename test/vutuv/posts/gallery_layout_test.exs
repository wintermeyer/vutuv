defmodule Vutuv.Posts.GalleryLayoutTest do
  @moduledoc """
  The bento arrangement catalog (the composer's "Muster" picker).

  Like `mosaic_layout_test.exs`, this checks the geometry directly: an
  arrangement one grid line off still renders a plausible mosaic, so every
  variant of every count must tile the 12×6 grid exactly. The automatic
  choice must keep reproducing the pre-catalog arrangements, because feeds
  full of existing posts render through it.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Posts.GalleryLayout

  @cols 12
  @rows 6

  defp area_cells(area) do
    [row_start, col_start, row_end, col_end] =
      area |> String.split(" / ") |> Enum.map(&String.to_integer/1)

    for row <- row_start..(row_end - 1), col <- col_start..(col_end - 1), do: {row, col}
  end

  describe "every variant of every count" do
    for count <- 2..5, variant <- GalleryLayout.variants(count) do
      test "#{count} photos, #{variant.name}: #{count} tiles fill the grid exactly" do
        variant = GalleryLayout.variant(unquote(count), unquote(variant.name))

        assert length(variant.areas) == unquote(count)

        cells = Enum.flat_map(variant.areas, &area_cells/1)
        assert length(cells) == length(Enum.uniq(cells))
        assert length(cells) == @cols * @rows
      end
    end

    test "both frames of every variant parse as a CSS aspect ratio" do
      for count <- GalleryLayout.counts(),
          variant <- GalleryLayout.variants(count),
          frame <- Tuple.to_list(variant.frames) do
        assert [w, h] = frame |> String.split(" / ") |> Enum.map(&String.to_integer/1)
        assert w > 0 and h > 0
      end
    end
  end

  describe "auto_variant/2" do
    test "reproduces the pre-catalog arrangement and frame for every count" do
      # {count, tall?} => {name, frame} as shipped before the catalog existed.
      expectations = %{
        {2, true} => {"pair", "7 / 5"},
        {2, false} => {"pair", "14 / 5"},
        {3, true} => {"hero-left", "6 / 5"},
        {3, false} => {"hero-top", "1 / 1"},
        {4, true} => {"grid", "4 / 5"},
        {4, false} => {"grid", "3 / 2"},
        {5, true} => {"hero-left", "7 / 5"},
        {5, false} => {"mosaic", "3 / 2"}
      }

      for {{count, tall?}, {name, frame}} <- expectations do
        variant = GalleryLayout.auto_variant(count, tall?)
        assert variant.name == name
        assert GalleryLayout.frame(variant, tall?) == frame
      end
    end
  end

  describe "cast/1" do
    test "keeps a known name and drops everything else" do
      assert GalleryLayout.cast("hero-left") == "hero-left"
      assert GalleryLayout.cast("columns") == "columns"
      assert GalleryLayout.cast("no-such-pattern") == nil
      assert GalleryLayout.cast(nil) == nil
      assert GalleryLayout.cast(42) == nil
    end
  end

  describe "variant/2" do
    test "a name that exists at another count is unavailable, not an error" do
      # "columns" is a three-photo arrangement only.
      assert GalleryLayout.variant(3, "columns")
      assert GalleryLayout.variant(4, "columns") == nil
      assert GalleryLayout.variant(2, "grid") == nil
    end
  end
end
