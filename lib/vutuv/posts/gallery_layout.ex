defmodule Vutuv.Posts.GalleryLayout do
  @moduledoc """
  The catalog of bento arrangements a multi-photo post can be laid out in.

  The mosaic (`VutuvWeb.PostComponents.mosaic/1`) has always chosen its
  arrangement automatically from the photo count and the hero's orientation.
  This module names those arrangements — plus a few more per count — so the
  composer can offer them as a choice: `posts.gallery_layout` stores one of
  the names here, `nil` means "automatic" and keeps the old behaviour to the
  pixel.

  A **variant** is an arrangement of N tiles on the shared 12×6 CSS grid
  (twelve columns divide by 2/3/4/6, six rows likewise — the same grid the
  mosaic has always used), plus a frame aspect per hero orientation. The frame
  stays orientation-tuned even for an explicitly chosen variant: the variant
  names *where the tiles sit*, while the frame keeps the hero's cell close to
  the hero's own shape (the "aspect-aware" property `mosaic_layout_test.exs`
  asserts).

  Names repeat across counts on purpose (`"hero-left"` exists for 3, 4 and 5
  photos): a member who adds or removes a photo keeps their arrangement idea
  wherever it exists at the new count, and where it does not the mosaic falls
  back to automatic rather than erroring.
  """

  @type variant :: %{name: String.t(), frames: {String.t(), String.t()}, areas: [String.t()]}

  # Per count: the variants, first one doubling as part of the automatic
  # choice. `frames` is `{portrait_hero, landscape_hero}` ("tall", "wide").
  # The frames of the automatically chosen variants reproduce the pre-catalog
  # values exactly; the rest are tuned by the same cell-aspect arithmetic
  # (cell = frame × cols/12 ÷ rows/6, see the mosaic's own comments).
  @variants %{
    2 => [
      %{
        name: "pair",
        frames: {"7 / 5", "14 / 5"},
        areas: ["1 / 1 / 7 / 7", "1 / 7 / 7 / 13"]
      },
      %{
        name: "lead-left",
        frames: {"5 / 4", "2 / 1"},
        areas: ["1 / 1 / 7 / 8", "1 / 8 / 7 / 13"]
      },
      %{
        name: "lead-right",
        frames: {"5 / 4", "2 / 1"},
        areas: ["1 / 6 / 7 / 13", "1 / 1 / 7 / 6"]
      },
      %{
        name: "stack",
        frames: {"2 / 3", "4 / 5"},
        areas: ["1 / 1 / 4 / 13", "4 / 1 / 7 / 13"]
      }
    ],
    3 => [
      %{
        name: "hero-left",
        frames: {"6 / 5", "2 / 1"},
        areas: ["1 / 1 / 7 / 9", "1 / 9 / 4 / 13", "4 / 9 / 7 / 13"]
      },
      %{
        name: "hero-top",
        frames: {"3 / 4", "1 / 1"},
        areas: ["1 / 1 / 5 / 13", "5 / 1 / 7 / 7", "5 / 7 / 7 / 13"]
      },
      %{
        name: "hero-right",
        frames: {"6 / 5", "2 / 1"},
        areas: ["1 / 5 / 7 / 13", "1 / 1 / 4 / 5", "4 / 1 / 7 / 5"]
      },
      %{
        name: "columns",
        frames: {"3 / 2", "2 / 1"},
        areas: ["1 / 1 / 7 / 5", "1 / 5 / 7 / 9", "1 / 9 / 7 / 13"]
      }
    ],
    4 => [
      %{
        name: "grid",
        frames: {"4 / 5", "3 / 2"},
        areas: ["1 / 1 / 4 / 7", "1 / 7 / 4 / 13", "4 / 1 / 7 / 7", "4 / 7 / 7 / 13"]
      },
      %{
        name: "hero-left",
        frames: {"7 / 5", "8 / 5"},
        areas: ["1 / 1 / 7 / 7", "1 / 7 / 3 / 13", "3 / 7 / 5 / 13", "5 / 7 / 7 / 13"]
      },
      %{
        name: "hero-top",
        frames: {"4 / 5", "1 / 1"},
        areas: ["1 / 1 / 5 / 13", "5 / 1 / 7 / 5", "5 / 5 / 7 / 9", "5 / 9 / 7 / 13"]
      }
    ],
    5 => [
      %{
        name: "hero-left",
        frames: {"7 / 5", "2 / 1"},
        areas: [
          "1 / 1 / 7 / 7",
          "1 / 7 / 4 / 10",
          "1 / 10 / 4 / 13",
          "4 / 7 / 7 / 10",
          "4 / 10 / 7 / 13"
        ]
      },
      %{
        name: "mosaic",
        frames: {"4 / 5", "3 / 2"},
        areas: [
          "1 / 1 / 5 / 9",
          "1 / 9 / 3 / 13",
          "3 / 9 / 5 / 13",
          "5 / 1 / 7 / 5",
          "5 / 5 / 7 / 13"
        ]
      },
      %{
        name: "hero-top",
        frames: {"4 / 5", "1 / 1"},
        areas: [
          "1 / 1 / 5 / 13",
          "5 / 1 / 7 / 4",
          "5 / 4 / 7 / 7",
          "5 / 7 / 7 / 10",
          "5 / 10 / 7 / 13"
        ]
      }
    ]
  }

  @names @variants |> Map.values() |> List.flatten() |> Enum.map(& &1.name) |> Enum.uniq()

  @doc "Every tile count the catalog has arrangements for."
  def counts, do: Map.keys(@variants)

  @doc "The variants available at `count` shown tiles (empty below two)."
  def variants(count) when is_integer(count), do: Map.get(@variants, count, [])

  @doc "The variant named `name` at `count`, or `nil` (unknown or unavailable)."
  def variant(count, name) when is_binary(name) do
    count |> variants() |> Enum.find(&(&1.name == name))
  end

  def variant(_count, _name), do: nil

  @doc """
  The variant the automatic choice picks — exactly the arrangement the mosaic
  used before layouts became selectable.
  """
  def auto_variant(count, tall?) do
    name =
      case {count, tall?} do
        {3, false} -> "hero-top"
        {5, false} -> "mosaic"
        _other -> hd(variants(count)).name
      end

    variant(count, name)
  end

  @doc "The frame aspect of `variant` for the hero's orientation."
  def frame(%{frames: {tall_frame, _wide}}, true), do: tall_frame
  def frame(%{frames: {_tall, wide_frame}}, false), do: wide_frame

  @doc """
  Validates a stored/submitted layout name: the name when it exists at any
  count, else `nil` (automatic). Availability at the post's actual photo count
  is the renderer's business — a name that is valid but absent at this count
  falls back to automatic there, so removing a photo never invalidates a post.
  """
  def cast(name) when name in @names, do: name
  def cast(_other), do: nil
end
