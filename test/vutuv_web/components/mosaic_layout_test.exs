defmodule VutuvWeb.MosaicLayoutTest do
  @moduledoc """
  The bento mosaic's geometry (issue #1104).

  The arrangement is the feature and it is much easier to get wrong than to
  see wrong — a tile placed one grid line off still renders a plausible-looking
  mosaic. So the layout function is checked directly: every photo gets a tile,
  the tiles tile the whole grid without overlapping, and the frame really does
  follow the hero's shape.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Posts.PostImage
  alias VutuvWeb.PostComponents

  defp photo(width, height), do: %PostImage{width: width, height: height, token: "t"}
  defp landscape, do: photo(3000, 2000)
  defp portrait, do: photo(2000, 3000)
  defp square, do: photo(2000, 2000)

  @cols 12
  @rows 6

  # "row-start / col-start / row-end / col-end" on the shared 12×6 grid.
  defp area_cells(area) do
    [row_start, col_start, row_end, col_end] =
      area |> String.split(" / ") |> Enum.map(&String.to_integer/1)

    for row <- row_start..(row_end - 1), col <- col_start..(col_end - 1), do: {row, col}
  end

  defp covered(layout), do: Enum.flat_map(layout.cells, &area_cells(&1.area))

  defp ratio(aspect) do
    [w, h] = aspect |> String.split(" / ") |> Enum.map(&String.to_integer/1)
    w / h
  end

  # What a tile actually looks like on screen: the frame's aspect scaled by how
  # much of each axis the tile spans. This — not the frame — is the number the
  # layouts are tuned to, so it is the one worth asserting.
  defp tile_aspect(layout, cell) do
    [row_start, col_start, row_end, col_end] =
      cell.area |> String.split(" / ") |> Enum.map(&String.to_integer/1)

    width_share = (col_end - col_start) / @cols
    height_share = (row_end - row_start) / @rows

    ratio(layout.aspect) * width_share / height_share
  end

  defp hero_aspect(layout), do: tile_aspect(layout, hd(layout.cells))

  describe "every count from two to five" do
    for count <- 2..5 do
      test "#{count} photos: each gets one tile, and the tiles fill the grid exactly" do
        for gallery <- [
              List.duplicate(landscape(), unquote(count)),
              List.duplicate(portrait(), unquote(count))
            ] do
          layout = PostComponents.mosaic_layout(gallery)

          assert length(layout.cells) == unquote(count)

          cells = covered(layout)
          # No two tiles may claim the same grid cell…
          assert length(cells) == length(Enum.uniq(cells))
          # …and together they must leave no gap in the 12×6 frame.
          assert length(cells) == @cols * @rows
        end
      end
    end
  end

  describe "the hero" do
    test "is the first photo and gets the largest tile" do
      hero = photo(4000, 3000)
      gallery = [hero, landscape(), landscape(), landscape()]

      [first | rest] = PostComponents.mosaic_layout(gallery).cells

      assert first.image == hero
      assert length(area_cells(first.area)) >= length(area_cells(hd(rest).area))
    end

    # The claim the whole layout table exists to make: the hero lands in a
    # tile shaped like the hero. Anything else and a mosaic is just a crop.
    for count <- 2..5 do
      test "#{count} photos: a portrait hero gets a portrait tile" do
        layout =
          PostComponents.mosaic_layout([
            portrait() | List.duplicate(portrait(), unquote(count) - 1)
          ])

        assert hero_aspect(layout) < 1.0
      end

      test "#{count} photos: a landscape hero gets a landscape tile" do
        layout =
          PostComponents.mosaic_layout([
            landscape() | List.duplicate(landscape(), unquote(count) - 1)
          ])

        assert hero_aspect(layout) > 1.0
      end
    end

    test "the hero tile stays close to the hero photo's own shape, not merely on its side of 1:1" do
      tall = PostComponents.mosaic_layout(List.duplicate(portrait(), 5))
      wide = PostComponents.mosaic_layout(List.duplicate(landscape(), 5))

      # 2:3 and 3:2 are the photos; a tile within a third of that crops gently.
      assert_in_delta hero_aspect(tall), 2 / 3, 0.25
      assert_in_delta hero_aspect(wide), 3 / 2, 0.25
    end

    test "a squarish hero is laid out like a landscape one, matching the card's own envelope" do
      squarish = PostComponents.mosaic_layout([square(), landscape(), landscape()])
      wide = PostComponents.mosaic_layout(List.duplicate(landscape(), 3))

      assert squarish.aspect == wide.aspect
    end
  end

  describe "more than five photos" do
    test "shows five tiles and folds the rest into a count on the last one" do
      layout = PostComponents.mosaic_layout(List.duplicate(landscape(), 9))

      assert length(layout.cells) == 5
      assert List.last(layout.cells).more == 4
      # …and only the last tile carries it, so the badge cannot land mid-mosaic.
      assert Enum.count(layout.cells, &(&1.more > 0)) == 1
    end

    test "exactly five photos show no overflow count" do
      layout = PostComponents.mosaic_layout(List.duplicate(landscape(), 5))

      assert length(layout.cells) == 5
      assert Enum.all?(layout.cells, &(&1.more == 0))
    end
  end

  describe "orientation/1" do
    test "buckets a photo by the same 5:4 / 4:5 envelope the post card uses" do
      assert PostImage.orientation(landscape()) == :landscape
      assert PostImage.orientation(portrait()) == :portrait
      assert PostImage.orientation(square()) == :square
    end

    test "a photo with no stored dimensions is treated as square, never crashes" do
      assert PostImage.orientation(%PostImage{}) == :square
      assert PostImage.aspect(%PostImage{}) == 1.0
    end
  end
end
