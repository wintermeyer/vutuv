defmodule VutuvWeb.OgImage do
  @moduledoc """
  The generated link-preview picture (`og:image`, 1200×630) for a page about
  one member or one post: what LinkedIn, X, Facebook, Bluesky, Mastodon,
  WhatsApp, Slack and iMessage draw when a vutuv URL is shared.

  A square avatar (`/:slug/avatar.jpg`, 512 px) gets the *small* card on every
  one of them — a thumbnail beside the title on LinkedIn and Facebook, the
  `summary` card on X — and X shows no title at all outside the picture, so a
  page shared there was a face and a domain. The wide card that carries the
  member's name, their headline and the opening of the post in its own pixels
  is the only shape every platform renders large.

  Composed with libvips (`Image`): text through Pango (`Vix.Vips.Operation.text`
  with markup), the round avatar and the tag pills through masks computed from
  pixel coordinates rather than rasterised SVG, so the card never depends on
  the librsvg loader that `VutuvWeb.OgCard` documents as absent on some hosts.
  The typeface is the first of `@font` fontconfig finds — Inter when the host
  has it (`fonts-inter` on Debian), else the platform sans — so the line
  metrics are measured at render time rather than assumed.

  The third shape, `square_png/1`, is for LinkedIn alone: its organic feed
  cuts a small square from the middle of whatever `og:image` it is given and
  shows it at roughly 128 px, so a square drawn as one — the face, the name
  and the first three or four lines in very large type — is what survives
  there, where the wide card's middle is a strip of headline.

  All three take plain data, not schemas, so the controller builds the map
  from the records and a script can build one from anything (that is how the
  design was iterated). `:error` on any libvips failure: the page falls back
  to the brand card, never to a 500 on a scraper's GET.
  """

  alias Vix.Vips.Image, as: Vimage
  alias Vix.Vips.Operation
  alias VutuvWeb.OgCard

  @width 1200
  @height 630
  @margin 72
  @bar 12
  @lift 24
  @square 1200
  @wordmark_width 150

  @font "Inter, Helvetica Neue, Helvetica, Arial, DejaVu Sans, sans-serif"

  # A line of invisible glyphs spanning ascender to descender (see `pango/5`).
  @ghost_line ~s(<span fgalpha="1">Ẫǧ</span>)

  # Direction A tokens (assets/css/app.css): slate ink on white, brand blue.
  @ink "#0f172a"
  @muted "#64748b"
  @faint "#94a3b8"
  @brand_700 "#1e40af"
  @brand_600 "#1d4ed8"
  @brand_500 "#2563eb"
  @brand_50 "#eff6ff"
  @white "#ffffff"

  def width, do: @width
  def height, do: @height
  def square, do: @square

  @typedoc """
  What a card is drawn from. `:avatar` is the member's square JPEG bytes
  (`Vutuv.Avatar.og_jpeg/1`), nil for a member without a picture.
  """
  @type data :: %{
          required(:name) => String.t(),
          optional(:headline) => String.t() | nil,
          optional(:avatar) => binary() | nil,
          optional(:tags) => [String.t()],
          optional(:footer) => String.t() | nil,
          optional(:text) => String.t() | nil,
          optional(:meta) => String.t() | nil
        }

  @doc """
  The profile card: the avatar on the left, and beside it — vertically
  centred as a block — the name, the headline, up to two rows of tag pills
  and the follower line; the profile's address in the footer.
  """
  @spec profile_png(data()) :: {:ok, binary()} | :error
  def profile_png(data) do
    render(fn card ->
      avatar_size = 260
      # Centred a little above the middle: the footer takes the bottom band.
      avatar_y = @bar + div(@height - @bar - avatar_size, 2) - @lift
      column_x = @margin + avatar_size + 56
      column_width = @width - @margin - column_x

      with {:ok, card} <- place_avatar(card, data[:avatar], avatar_size, @margin, avatar_y),
           {:ok, blocks} <-
             blocks([
               {fn -> text_block(data.name, column_width, 54, weight: :bold, lines: 2) end, 0},
               {fn -> text_block(data[:headline], column_width, 30, color: @muted, lines: 2) end,
                14},
               {fn -> pill_row(data[:tags] || [], column_width) end, 28},
               {fn -> text_block(data[:meta], column_width, 26, color: @faint) end, 26}
             ]),
           {:ok, card} <- stack(card, blocks, column_x, centred_top(blocks) - @lift) do
        footer(card, data[:footer])
      end
    end)
  end

  @doc """
  The post card: the author's avatar, name and headline as the header, the
  opening of the post as the body, the date and the post's address in the
  footer.
  """
  @spec post_png(data()) :: {:ok, binary()} | :error
  def post_png(data) do
    render(fn card ->
      avatar_size = 88
      header_x = @margin + avatar_size + 24
      header_width = @width - @margin - header_x
      body_top = @margin + avatar_size + 40
      body_height = @height - body_top - @margin - 56

      with {:ok, card} <- place_avatar(card, data[:avatar], avatar_size, @margin, @margin),
           {:ok, header} <-
             blocks([
               {fn -> text_block(data.name, header_width, 34, weight: :bold) end, 0},
               {fn -> text_block(data[:headline], header_width, 24, color: @muted) end, 6}
             ]),
           {:ok, card} <- stack(card, header, header_x, @margin + 4),
           {:ok, body} <- body_block(data[:text], @width - 2 * @margin, body_height),
           {:ok, card} <- place(card, body, @margin, body_top) do
        footer(card, data[:footer], data[:meta])
      end
    end)
  end

  @doc """
  The square post card for LinkedIn's thumbnail: the face and the name on
  top, the opening of the post in type large enough to survive a ninefold
  reduction, the wordmark at the foot. No headline, no date, no address —
  at 128 px none of them would be legible.
  """
  @spec square_png(data()) :: {:ok, binary()} | :error
  def square_png(data) do
    margin = 80
    avatar_size = 240
    name_x = margin + avatar_size + 40
    name_width = @square - margin - name_x
    body_top = margin + avatar_size + 72
    body_height = @square - body_top - margin - 100

    render({@square, @square}, fn card ->
      with {:ok, card} <- place_avatar(card, data[:avatar], avatar_size, margin, margin),
           {:ok, name} <-
             blocks([
               {fn -> text_block(data.name, name_width, 88, weight: :bold, lines: 2) end, 0}
             ]),
           {:ok, card} <-
             stack(card, name, name_x, margin + div(avatar_size - stack_height(name), 2)),
           {:ok, body} <-
             body_block(data[:text], @square - 2 * margin, body_height, [136, 120, 108], 4),
           {:ok, card} <- place(card, body, margin, body_top),
           {:ok, mark} <- OgCard.wordmark(200, @brand_600) do
        Image.compose(card, mark, x: margin, y: @square - margin - Image.height(mark))
      end
    end)
  end

  # ---------------------------------------------------------------- canvas

  defp render(size \\ {@width, @height}, draw)

  defp render({width, height}, draw) do
    with {:ok, card} <- Image.new(width, height, color: @white),
         {:ok, bar} <- bar(width),
         {:ok, card} <- Image.compose(card, bar, x: 0, y: 0),
         {:ok, card} <- draw.(card),
         {:ok, card} <- Image.flatten(card),
         {:ok, png} <- Image.write(card, :memory, suffix: ".png") do
      {:ok, png}
    else
      _ -> :error
    end
  rescue
    # A libvips failure (a missing font, a corrupt avatar) degrades to "no
    # generated card" — the page keeps its brand card — never to a 500.
    _ -> :error
  end

  # The brand gradient along the top edge, built once per width.
  defp bar(width) do
    cached({:bar, width}, fn ->
      Image.linear_gradient(width, @bar,
        start_color: @brand_700,
        finish_color: @brand_500,
        angle: 90
      )
    end)
  end

  # The wordmark bottom-left in brand blue; an address and, on a post card, a
  # date bottom-right in the faint ink.
  defp footer(card, address, meta \\ nil) do
    baseline = @height - @margin - 36

    with {:ok, mark} <- OgCard.wordmark(@wordmark_width, @brand_600),
         {:ok, card} <- Image.compose(card, mark, x: @margin, y: baseline + 2),
         {:ok, line} <- text_block(joined(meta, address), @width - 2 * @margin, 24, color: @faint) do
      place(card, line, @width - @margin - block_width(line), baseline)
    end
  end

  # Pixels that are the same on every card — the bar, the avatar masks — are
  # built once, materialised (a lazy libvips graph would be re-evaluated on
  # every write) and kept in `:persistent_term` beside the font metrics.
  defp cached(key, build) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil ->
        with {:ok, img} <- build.(),
             {:ok, img} <- Vimage.copy_memory(img) do
          :persistent_term.put({__MODULE__, key}, img)
          {:ok, img}
        end

      img ->
        {:ok, img}
    end
  end

  defp joined(nil, address), do: address
  defp joined(meta, nil), do: meta
  defp joined(meta, address), do: "#{meta}   ·   #{address}"

  # ---------------------------------------------------------------- blocks

  # A block is an image (or nil for "nothing to draw") that a card stacks
  # vertically. `blocks/1` builds a list of `{image, gap_before}` from thunks,
  # dropping the empty ones together with their gap, so a member with no
  # headline does not leave a hole where it would have been.
  defp blocks(thunks) do
    Enum.reduce_while(thunks, {:ok, []}, fn {thunk, gap}, {:ok, acc} ->
      case thunk.() do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, img} -> {:cont, {:ok, [{img, if(acc == [], do: 0, else: gap)} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp stack_height(blocks),
    do: Enum.reduce(blocks, 0, fn {img, gap}, sum -> sum + gap + Image.height(img) end)

  # The y at which a stack sits vertically centred in the card below the bar.
  defp centred_top(blocks), do: @bar + div(@height - @bar - stack_height(blocks), 2)

  defp stack(card, blocks, x, y) do
    Enum.reduce_while(blocks, {:ok, card, y}, fn {img, gap}, {:ok, card, y} ->
      case Image.compose(card, img, x: x, y: y + gap) do
        {:ok, card} -> {:cont, {:ok, card, y + gap + Image.height(img)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, card, _y} -> {:ok, card}
      error -> error
    end
  end

  defp place(card, nil, _x, _y), do: {:ok, card}
  defp place(card, img, x, y), do: Image.compose(card, img, x: x, y: y)

  defp block_width(nil), do: 0
  defp block_width(img), do: Image.width(img)

  # ---------------------------------------------------------------- text

  # `string` wrapped to `width` in `size` px, at most `:lines` lines (default
  # 1): a longer text is cut on a word boundary and ends in an ellipsis. A
  # string with nothing drawable in it (nil, "", emoji alone) is no block at
  # all.
  defp text_block(string, width, size, style) do
    case clean(string) do
      "" ->
        {:ok, nil}

      text ->
        lines = Keyword.get(style, :lines, 1)
        weight = Keyword.get(style, :weight, :normal)
        color = Keyword.get(style, :color, @ink)

        with {:ok, max_height} <- max_height(size, lines) do
          fitted(text, width, max_height, size, weight, color)
        end
    end
  end

  # The post body: the largest of the `sizes` at which the whole opening fits
  # `lines` lines, so a two-line post reads big and a long one still shows its
  # first lines at the smallest size, cut there. `height` caps the block on
  # top of that.
  defp body_block(string, width, height, sizes \\ [44, 40, 36], lines \\ 6) do
    case clean(string) do
      "" -> {:ok, nil}
      text -> body_block_at(text, width, height, sizes, lines)
    end
  end

  defp body_block_at(string, width, height, sizes, lines) do
    {larger, [floor]} = Enum.split(sizes, -1)

    case cap(string, width, floor, lines) do
      {:whole, string} ->
        Enum.find_value(larger, &whole_block(string, width, height, &1, lines)) ||
          floor_block(string, width, height, floor, lines)

      {:cut, string} ->
        floor_block(string, width, height, floor, lines)
    end
  end

  # The whole text at `size`, or nil when it does not fit `lines` lines.
  defp whole_block(string, width, height, size, lines) do
    with {:ok, tallest} <- max_height(size, lines),
         {:ok, img, false} <- measured(string, width, min(tallest, height), size) do
      {:ok, img}
    else
      _ -> nil
    end
  end

  defp floor_block(string, width, height, floor, lines) do
    with {:ok, tallest} <- max_height(floor, lines) do
      fitted(string, width, min(tallest, height), floor, :normal, @ink)
    end
  end

  # More characters than could fill `lines` lines at `size` even in a narrow
  # face are cut before anything is rendered: Pango lays the whole text out
  # first, and a long body at the square card's 136 px runs past the largest
  # surface Cairo allows — which came back as an error rather than a card.
  # Generous (0.3 em per character), so nothing that could have fit is lost;
  # a cut text takes the floor size, since it cannot fit whole at a larger one.
  defp cap(string, width, size, lines) do
    most = trunc(lines * width / (size * 0.3))

    if String.length(string) > most,
      do: {:cut, Regex.replace(~r/\s+\S*\z/u, String.slice(string, 0, most), "")},
      else: {:whole, string}
  end

  # Renders `string` wrapped to `width`; if the block is taller than
  # `max_height`, cuts it to about the share that fits and then a word at a
  # time until it does, closing with "…". The first cut is by the overshoot
  # (a 600-character opening at six lines' room is two or three renders, not
  # forty), the rest by the word.
  defp fitted(string, width, max_height, size, weight, color) do
    case measured(string, width, max_height, size, weight, color) do
      {:ok, img, false} ->
        {:ok, img}

      {:ok, img, true} ->
        string
        |> about(max_height / Image.height(img))
        |> shorter()
        |> fitted(width, max_height, size, weight, color)

      error ->
        error
    end
  end

  # The leading share of `string` a block that overshoots by 1/`share` is
  # likely to fit at, on a word boundary — a little over rather than under,
  # because the word loop after it only ever shortens: a cut that lands short
  # of the room costs a line of the card, one that lands long costs a render
  # or two. The whole string when the overshoot is under two lines or so:
  # lines wrap unevenly, and there a character share lands a whole line short
  # where three or four word cuts land exactly.
  defp about(string, share) when share > 0.6, do: string

  defp about(string, share) do
    keep = trunc(String.length(string) * share * 1.2)
    Regex.replace(~r/\s+\S*\z/u, String.slice(string, 0, keep), "")
  end

  defp measured(string, width, max_height, size, weight \\ :normal, color \\ @ink) do
    with {:ok, img} <- pango(string, width, size, weight, color) do
      {:ok, img, Image.height(img) > max_height}
    end
  end

  # Drops the last word (past the last space, the last character) and closes
  # with an ellipsis. Line breaks in the rest of the text are kept. A string
  # that cannot be shortened further keeps a single character, so the
  # recursion always ends.
  defp shorter(string) do
    base = string |> String.trim_trailing("…") |> String.trim_trailing()

    cut =
      case Regex.replace(~r/\s+\S+\s*\z/u, base, "") do
        "" -> String.slice(base, 0, max(String.length(base) - 1, 1))
        rest -> rest
      end

    Regex.replace(~r/[\s,.;:–-]+\z/u, cut, "") <> "…"
  end

  # The text through Pango as an RGBA image with a consistent line box. Pango
  # (via libvips) trims the picture to the ink, so "PHP" and "open source"
  # come back with different heights and different tops, which no baseline
  # can be aligned from. So the text is rendered between two lines of
  # invisible glyphs — one reaching the ascender line, one the descender, at
  # alpha 1/65535 — and those lines are cropped off again by the measured
  # pitch: what is left spans the full line box of the first and last visible
  # lines, whatever their letters, and the ink trim of the visible glyphs
  # alone decides the width.
  defp pango(string, width, size, weight, color) do
    span = ~s(<span foreground="#{color}" weight="#{weight}">#{escape(string)}</span>)

    with {:ok, {_single, pitch}} <- metrics(size),
         {:ok, img} <- raw_text(@ghost_line <> "\n" <> span <> "\n" <> @ghost_line, width, size),
         {:ok, alpha} <- Operation.extract_band(img, 3),
         {:ok, {left, _top, ink_width, _h}} <-
           Operation.find_trim(alpha, threshold: 0, background: [0.0]),
         true <- ink_width > 0 and Image.height(img) > 2 * pitch do
      Image.crop(img, left, pitch, ink_width, Image.height(img) - 2 * pitch)
    else
      false -> {:error, :blank}
      error -> error
    end
  end

  defp raw_text(markup, width, size) do
    with {:ok, {img, _flags}} <-
           Operation.text(markup,
             font: "#{@font} #{size}",
             dpi: 72,
             rgba: true,
             width: width,
             wrap: :VIPS_TEXT_WRAP_WORD,
             align: :VIPS_ALIGN_LOW
           ) do
      {:ok, img}
    end
  end

  defp escape(string), do: string |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()

  # One line's box and the pitch between two lines at this size, in the font
  # fontconfig actually picked — measured, not assumed, and cached per size.
  defp metrics(size) do
    case :persistent_term.get({__MODULE__, :metrics, size}, nil) do
      nil ->
        with {:ok, one} <- raw_text(@ghost_line, 200, size),
             {:ok, two} <- raw_text(@ghost_line <> "\n" <> @ghost_line, 200, size) do
          single = Image.height(one)
          metrics = {single, Image.height(two) - single}
          :persistent_term.put({__MODULE__, :metrics, size}, metrics)
          {:ok, metrics}
        end

      metrics ->
        {:ok, metrics}
    end
  end

  # The tallest `lines`-line block this size can produce, with a pixel of
  # slack for rounding.
  defp max_height(size, lines) do
    with {:ok, {single, pitch}} <- metrics(size) do
      {:ok, single + (lines - 1) * pitch + 1}
    end
  end

  # Whitespace folded; emoji and other pictographs dropped, because Pango draws
  # them from a monochrome fallback face as black silhouettes. nil is "".
  defp clean(nil), do: ""

  defp clean(string) do
    string
    |> String.replace(~r/[\p{So}\p{Sk}\p{Cs}\x{FE0F}\x{200D}]/u, "")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/ *\n[ \n]*/, "\n")
    |> String.trim()
  end

  # ---------------------------------------------------------------- pills

  # Up to two rows of tag pills in brand-50 with brand-700 text, as many as
  # fit, on a transparent layer the caller stacks like a text block. No tags,
  # no block.
  defp pill_row(tags, width) do
    case tags |> Enum.map(&clean/1) |> Enum.reject(&(&1 == "")) do
      [] -> {:ok, nil}
      labels -> pill_row_of(labels, width)
    end
  end

  @pill %{size: 24, pad_x: 18, height: 44, gap: 12, rows: 2}

  defp pill_row_of(tags, width) do
    %{height: height, gap: gap, rows: rows} = @pill

    with {:ok, layer} <-
           Image.new(width, rows * height + (rows - 1) * gap, color: [0, 0, 0, 0], bands: 4),
         {:ok, layer, rows_used} when rows_used > 0 <- draw_pills(layer, tags, width) do
      Image.crop(layer, 0, 0, width, rows_used * height + (rows_used - 1) * gap)
    else
      # Not one pill fit (a single tag wider than the column): no block.
      {:ok, _layer, 0} -> {:ok, nil}
      error -> error
    end
  end

  # Pills left to right, row by row, until one no longer fits; answers the
  # layer and how many rows it used — zero when even the first was refused.
  defp draw_pills(layer, tags, width) do
    Enum.reduce_while(tags, {:ok, layer, 0, 0}, fn tag, {:ok, layer, x, row} ->
      case draw_pill(layer, tag, {x, row}, width) do
        {:ok, layer, x, row} -> {:cont, {:ok, layer, x, row}}
        :full -> {:halt, {:ok, layer, x, row}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _layer, 0, 0} -> {:ok, layer, 0}
      {:ok, layer, _x, row} -> {:ok, layer, row + 1}
      error -> error
    end
  end

  # One pill at the next free slot from (x, row): the slot after it, or
  # `:full` when neither this row nor the next has room.
  defp draw_pill(layer, tag, {x, row}, width) do
    %{size: size, pad_x: pad_x, height: height, gap: gap} = @pill

    with {:ok, label} <- pango(tag, width, size, :normal, @brand_700),
         pill_width = Image.width(label) + 2 * pad_x,
         {:ok, x, row} <- pill_slot(x, row, pill_width, width),
         y = row * (height + gap),
         {:ok, pill} <- rounded_rect(pill_width, height, div(height, 2), @brand_50),
         {:ok, layer} <- Image.compose(layer, pill, x: x, y: y),
         {:ok, layer} <-
           Image.compose(layer, label,
             x: x + pad_x,
             y: y + div(height - Image.height(label), 2)
           ) do
      {:ok, layer, x + pill_width + gap, row}
    end
  end

  # Where the next pill goes: on this row if it fits, else at the start of the
  # next, `:full` once the rows are spent.
  defp pill_slot(x, row, pill_width, width) do
    cond do
      x + pill_width <= width -> {:ok, x, row}
      row + 1 < @pill.rows and pill_width <= width -> {:ok, 0, row + 1}
      true -> :full
    end
  end

  # ---------------------------------------------------------------- pictures

  # The round avatar at (x, y); a member without a picture gets a brand-50
  # disc, so the card keeps its shape.
  defp place_avatar(card, nil, size, x, y) do
    with {:ok, disc} <- rounded_rect(size, size, div(size, 2), @brand_50) do
      Image.compose(card, disc, x: x, y: y)
    end
  end

  defp place_avatar(card, jpeg, size, x, y) when is_binary(jpeg) do
    with {:ok, img} <- Image.open(jpeg),
         {:ok, img} <- Image.thumbnail(img, size, crop: :center),
         {:ok, img} <- Image.flatten(img),
         {:ok, mask} <- cached({:circle, size}, fn -> circle_mask(size) end),
         {:ok, round} <- Image.add_alpha(img, mask) do
      Image.compose(card, round, x: x, y: y)
    end
  end

  # ---------------------------------------------------------------- masks

  # A filled rounded rectangle with an anti-aliased edge, as an RGBA image.
  defp rounded_rect(width, height, radius, color) do
    with {:ok, fill} <- Image.new(width, height, color: color),
         {:ok, mask} <- rounded_mask(width, height, radius) do
      Image.add_alpha(fill, mask)
    end
  end

  defp circle_mask(size), do: rounded_mask(size, size, size / 2)

  # The signed distance from each pixel centre to a rounded rectangle, turned
  # into coverage: 255 inside, 0 outside, a one-pixel ramp on the edge. Pure
  # pixel arithmetic — `Image.rounded/2` and `Image.avatar/2` rasterise an SVG
  # for the same mask, which needs the librsvg loader.
  defp rounded_mask(width, height, radius) do
    cx = (width - 1) / 2
    cy = (height - 1) / 2
    inner_x = width / 2 - radius
    inner_y = height / 2 - radius

    with {:ok, xyz} <- Operation.xyz(width, height),
         {:ok, x} <- Operation.extract_band(xyz, 0),
         {:ok, y} <- Operation.extract_band(xyz, 1),
         {:ok, dx} <- corner_distance(x, cx, inner_x),
         {:ok, dy} <- corner_distance(y, cy, inner_y),
         {:ok, dx2} <- Operation.multiply(dx, dx),
         {:ok, dy2} <- Operation.multiply(dy, dy),
         {:ok, d2} <- Operation.add(dx2, dy2),
         {:ok, d} <- Operation.math2_const(d2, :VIPS_OPERATION_MATH2_POW, [0.5]),
         # coverage = clip((radius + 0.5 - d) * 255, 0, 255); the cast clips.
         {:ok, cov} <- Operation.linear(d, [-255.0], [(radius + 0.5) * 255]) do
      Operation.cast(cov, :VIPS_FORMAT_UCHAR)
    end
  end

  # max(|v - centre| - inner, 0), the distance past the straight part of the
  # edge; zero along the flat sides. max(a, 0) = (a + |a|) / 2 keeps it to
  # arithmetic libvips has.
  defp corner_distance(band, centre, inner) do
    with {:ok, shifted} <- Operation.linear(band, [1.0], [-centre]),
         {:ok, abs} <- Operation.abs(shifted),
         {:ok, past} <- Operation.linear(abs, [1.0], [-inner]),
         {:ok, past_abs} <- Operation.abs(past),
         {:ok, sum} <- Operation.add(past, past_abs) do
      Operation.linear(sum, [0.5], [0.0])
    end
  end
end
