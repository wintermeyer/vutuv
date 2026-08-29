defmodule Vutuv.Uploads.Spec do
  @moduledoc """
  The single source of truth for every **served** image version: resolution,
  fit/crop mode, output format and encoder quality, plus the one shared write
  pipeline all uploaders go through. A future format or compression change is
  an edit here followed by `Vutuv.Uploads.Regenerator.run/1`, which re-derives
  everything from the kept originals.

  Served versions are AVIF. Derived sizes are ~2x their largest CSS display
  size so they stay crisp on HiDPI screens (avatar slots per `VutuvWeb.UI`:
  xs 32 / sm 36 / md 48 / lg 96 px) — except the versions that exist to be
  *looked at* rather than to fill a layout slot (`post_image` `xl`, `avatar`
  `large`), which are sized for the lightbox's full screen.

  The write pipeline is decode → `Image.autorotate` (`open_rotated/1`, once
  per upload) → resize per `fit` → `Vix.Vips.Operation.heifsave` with
  `keep: []`. EXIF autorotation must happen **before** metadata stripping —
  orientation is itself EXIF data, stripping first renders portrait phone
  photos sideways. `keep: []` is the only reliable strip: `Image.write(...,
  strip_metadata: true)` maps to the legacy `strip` saver param, which current
  libvips builds accept and silently ignore. heifsave defaults to HEVC, which
  the precompiled vix libheif cannot encode (patent licensing), so the AV1
  compression is set explicitly; `test/vutuv/uploads/spec_test.exs` fails
  loudly on a build that cannot encode AVIF.

  Originals are **not** versions: every uploader keeps the upload verbatim
  (format + metadata — the point of keeping it is re-deriving better formats
  later) in a private location that is never served.
  """

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @served_ext ".avif"
  # Extensions a derived version may carry on disk from before the AVIF
  # switch; URL/path resolution falls back to these until the one-shot
  # regeneration has converted everything (then this fallback gets removed).
  @legacy_exts ~w(.webp .jpg .jpeg .png)

  @effort 4

  # The pixelated preview (issue #1720): how many cells the long edge is reduced
  # to before it is blown back up, and how big the blown-up file is.
  #
  # 64 cells is the second setting this had. At 32 the tile read as a colour
  # field rather than as the photo somebody is waiting for, which is the whole
  # job it has; 64 keeps the composition legible — a person is a person, a
  # screenshot is a screenshot — while a face is still a handful of flat
  # squares and a line of text is gone entirely. Past this it stops being a
  # placeholder: what stands here is a picture nobody has looked at yet.
  #
  # The blow-up width scales with the cells so a block stays ~15px in the file
  # and the tile never softens on a wide card. Quality is lower than any served
  # version because flat blocks compress to nothing.
  @pixelated_cells 64
  @pixelated_width 960
  @pixelated_quality 50

  # `fit` shapes: {:crop, w, h, gravity} crops to exactly w×h;
  # {:crop_down, s, gravity} crops to a square of at most s×s;
  # {:box_down, s} fits within s×s; {:width_down, w} caps the width —
  # every *_down variant never upscales a smaller source.
  #
  # heifsave's Q scale is not WebP's: the former WebP Q80 is visually
  # ~AVIF Q58-63. Avatars get Q62 (blocking is most visible at tiny sizes
  # and the bytes are tiny anyway), photographic content Q58.
  # The three layout slots a picture attached to a *page* needs — a job posting's
  # image and an organization's logo / cover / gallery shot. Written once and
  # named twice below, because the organization store used to derive from
  # `:post_image` instead and so paid for a fourth, 2560px `xl` version that no
  # URL of its own can serve: its proxy whitelist, `version_path/2` and
  # `accel_path/2` all guard on the three names.
  @page_image_versions [
    %{name: :thumb, fit: {:crop, 320, 320, :center}, quality: 58},
    %{name: :feed, fit: {:box_down, 1200}, quality: 58},
    %{name: :large, fit: {:box_down, 1600}, quality: 58}
  ]

  @specs %{
    avatar: [
      %{name: :thumb, fit: {:crop, 96, 96, :center}, quality: 62},
      %{name: :medium, fit: {:crop, 192, 192, :center}, quality: 62},
      # The version behind the profile header's click-to-enlarge (issue #1528).
      # Like `post_image` `xl` it is sized for the lightbox rather than for a
      # slot: 1024 is ~3x a phone's overlay width at DPR 3, and on a desktop it
      # is the picture at its own size on a dark screen. It is `crop_down`, not
      # `crop`, because an avatar is the one upload members routinely hand us
      # smaller than the version we want — upscaling a 300px selfie to 1024
      # would cost bytes for pixels that carry nothing.
      %{name: :large, fit: {:crop_down, 1024, :center}, quality: 62}
    ],
    cover: [
      # Displayed ~768px wide on HiDPI; aspect ratio preserved, the display
      # crop is CSS object-cover, so tall photos are never baked away here.
      %{name: :wide, fit: {:width_down, 1600}, quality: 58}
    ],
    screenshot: [
      # 2x the 400x264 on-page display size; crop :high keeps the page top.
      %{name: :thumb, fit: {:crop, 800, 528, :high}, quality: 58}
    ],
    review_cover: [
      # A book cover fetched by ISBN (Vutuv.ReviewCover): portrait aspect
      # preserved. Deliberately the smallest size that still looks sharp —
      # ~3x the review card's 64-96px display width, enough for HiDPI and no
      # more. This is somebody else's cover quoted beside a review (§ 51
      # UrhG), and a quote stays as short as its purpose needs; a copy larger
      # than we display would be one we cannot justify.
      %{name: :cover, fit: {:box_down, 320}, quality: 58}
    ],
    # A picture attached to a post by an account somebody here follows
    # (`Vutuv.RemoteMedia`, issue #1163). One version, aspect preserved, sized
    # for the feed column and its HiDPI double — and no further. The same
    # reasoning as the review cover: this is somebody else's picture shown
    # beside their post, and a copy larger than we display is one we cannot
    # justify keeping. It is also why there is no lightbox `xl` here; the
    # full-size original is one click away on their own server.
    remote_media: [
      %{name: :image, fit: {:box_down, 1200}, quality: 58}
    ],
    # The avatar of such an account: the same two sizes a member's own avatar
    # gets would be two files for a picture only ever shown at 36-56px, so it
    # is one.
    remote_avatar: [
      %{name: :image, fit: {:crop, 192, 192, :center}, quality: 62}
    ],
    post_image: [
      # thumb: square feed-grid / mosaic cell; feed: single-image feed width;
      # large: the permalink gallery; xl: the lightbox.
      #
      # `xl` exists because on a photo post the picture *is* the content
      # (issue #1104): 1600px is a fine page image and a soft one filling a
      # 4K screen, which is exactly what the lightbox does. It is the one
      # version sized for looking at rather than for a layout slot, so it is
      # also the only one worth its extra bytes — nothing else requests it.
      %{name: :thumb, fit: {:crop, 320, 320, :center}, quality: 58},
      %{name: :feed, fit: {:box_down, 1200}, quality: 58},
      %{name: :large, fit: {:box_down, 1600}, quality: 58},
      %{name: :xl, fit: {:box_down, 2560}, quality: 60}
    ],
    # Job-posting gallery images: same sizes as post images.
    job_posting_image: @page_image_versions,
    organization_image: @page_image_versions,
    # The proof document on a certificate/license (Vutuv.QualificationDocument):
    # one aspect-preserving thumbnail (typically a portrait A4 scan), displayed
    # up to ~256px wide — the full document is a click away.
    qualification_document: [
      %{name: :thumb, fit: {:box_down, 640}, quality: 58}
    ],
    # An Arbeitszeugnis (Vutuv.JobReferenceDocument). Same shape as a
    # qualification's proof — a portrait A4 scan shown as a card thumbnail —
    # but with a second, larger version: a Zeugnis is a page of prose the
    # member wants to skim before opening it, and 640px is too small to read.
    job_reference_document: [
      %{name: :thumb, fit: {:box_down, 640}, quality: 58},
      %{name: :page, fit: {:box_down, 1400}, quality: 60}
    ]
  }

  @doc "The extension every served version carries."
  def served_ext, do: @served_ext

  @doc "Extensions pre-AVIF derived files may still carry on disk."
  def legacy_exts, do: @legacy_exts

  @doc "The ordered version specs of an image type."
  def versions(type), do: Map.fetch!(@specs, type)

  @doc "A single version spec of an image type."
  def version(type, name) do
    type |> versions() |> Enum.find(&(&1.name == name)) ||
      raise ArgumentError, "unknown #{type} version #{inspect(name)}"
  end

  @doc """
  The widest pixel width `type` is ever stored at. Every `fit` never upscales,
  so this is also the point past which more pixels are thrown away — which is
  what the upload forms tell members to aim for (`VutuvWeb.UI`'s recommended
  avatar/cover sizes read it, so a resolution change here moves the advice).
  """
  def max_width(type) do
    type |> versions() |> Enum.map(&fit_width/1) |> Enum.max()
  end

  defp fit_width(%{fit: {:crop, width, _height, _gravity}}), do: width
  defp fit_width(%{fit: {:crop_down, size, _gravity}}), do: size
  defp fit_width(%{fit: {:box_down, size}}), do: size
  defp fit_width(%{fit: {:width_down, width}}), do: width

  @doc """
  Decodes `path` and applies the EXIF orientation, returning
  `{:ok, %Vix.Vips.Image{}}` ready for `write_derived/3` (decode and rotate
  once, then derive all versions from it) or `{:error, reason}` when the file
  cannot be decoded.

  An SVG is rasterised here rather than decoded: it has no pixels of its own,
  so opening one plainly yields whatever size its `width`/`height` attributes
  happen to name — a 64px logo would come out as a 64px picture and every
  derived version would be a blur. It is rendered at `svg_raster_size/0`
  instead, which covers the largest version any type stores an SVG-sourced
  image at.

  Which file is an SVG is decided by its **first bytes**, never its name: what
  arrives here is the upload's temporary file, which has no extension at all
  (`consume_uploaded_entries` hands over `/tmp/live_view_upload-…`), and libvips
  itself picks its loader by content — so a `.png` holding SVG markup renders as
  SVG whatever the whitelist believed.
  """
  # A generous ceiling — far above any real avatar/cover/post photo (all
  # downscaled to ≤1600px), far below the pixel-flood "decompression bombs"
  # that slip past the byte-size gate: a flat 30000×30000 PNG is ~2 MB on disk
  # but ~3.6 GB once decoded. The dimensions come from the header, so an
  # oversized image is rejected before autorotate/thumbnail pull its pixels.
  @max_megapixels 50

  # Rendered by `svg_supported?/0` to prove this build really draws SVG.
  @svg_probe ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">) <>
               ~s(<rect width="8" height="8" fill="#000"/></svg>)

  def open_rotated(path) do
    if svg_content?(path) do
      open_svg(path)
    else
      with {:ok, image} <- Image.open(path),
           :ok <- within_pixel_budget(image),
           {:ok, {rotated, _flags}} <- Image.autorotate(image) do
        {:ok, rotated}
      end
    end
  end

  @doc """
  Whether this build can rasterise an SVG — librsvg inside libvips, the way
  `.heic` needs an HEVC decoder inside libheif.

  Probed the way `Vutuv.PostImageStore.heic_supported?/0` probes its format,
  and for the reason that one records: vips is lazy, so a build can register
  the loader and still fail at the point pixels are materialised. The verdict
  is cached for the VM's lifetime.
  """
  def svg_supported? do
    case :persistent_term.get({__MODULE__, :svg_supported}, :unknown) do
      :unknown ->
        supported =
          with {:ok, {image, _flags}} <- Operation.svgload_buffer(@svg_probe),
               {:ok, _binary} <- VipsImage.write_to_binary(image) do
            true
          else
            _ -> false
          end

        :persistent_term.put({__MODULE__, :svg_supported}, supported)
        supported

      verdict ->
        verdict
    end
  end

  @doc """
  The long edge an SVG is rasterised at: the widest version an organization
  image is stored at, since that is the only type whose whitelist takes one.
  Read off the version table rather than written out, so a resolution change
  there moves the raster size with it. Every `fit` downscales from here and
  none upscales — a type with a bigger version (post `xl` is 2560) starting to
  take SVGs would want this widened.
  """
  def svg_raster_size, do: max_width(:organization_image)

  # How far in an `<svg` may sit: past an XML declaration, a DOCTYPE, a comment
  # or a licence header. Deliberately more than the ~1000 bytes libvips' own SVG
  # sniff reads, so anything it is willing to hand to the SVG renderer is
  # recognised here first — a smaller window would leave files that render as
  # SVG but were never vetted as one.
  @svg_sniff_bytes 2048

  # Whether a file / a blob holds SVG markup, judged by its opening bytes.
  # Every SVG decision in the pipeline hangs off content rather than a
  # filename: an upload's temporary file has no extension, and libvips picks
  # its loader by content anyway, so a file *named* `.png` that holds `<svg>`
  # is an SVG to everything downstream and has to be one here too.
  defp svg_content?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @svg_sniff_bytes)) do
      {:ok, head} when is_binary(head) -> svg_head?(head)
      _ -> false
    end
  end

  defp svg_binary?(binary) do
    binary |> binary_part(0, min(byte_size(binary), @svg_sniff_bytes)) |> svg_head?()
  end

  defp svg_head?(head), do: String.contains?(String.downcase(head), "<svg")

  # Code, and the entity lever the parser pulls before we ever see pixels:
  #
  #   * a DOCTYPE is where an entity declaration lives — XXE (read a local file
  #     into the picture) and billion-laughs (expand until the box is out of
  #     memory); a drawing has no use for one
  #   * `<script>` and `javascript:` are code
  #   * `<foreignObject>` embeds arbitrary HTML, and with it scripts
  #   * `@import` pulls another stylesheet into the render
  #
  # One caseless regex rather than six `String.contains?` over a downcased
  # copy: the copy alone costs ~20 ms per MB of markup, six times what the
  # matching costs.
  @svg_forbidden ~r/<!doctype|<!entity|<script|<foreignobject|javascript:|@import/i

  # A reference the renderer would actually go and *fetch*: an <image> or <use>
  # pointing at a URL or at a path on our disk.
  @svg_external_ref ~r/(?:xlink:)?href\s*=\s*["']?\s*(?:https?:|file:|\/\/)/i

  # Whether SVG markup is something we are willing to hand to the renderer.
  #
  # A rasterised SVG never reaches a browser here — every proxy serves the
  # derived AVIF versions only — so this is not an XSS gate but a *renderer*
  # gate: the XML parser runs on our server, on markup a member (or a remote
  # server) chose, and left alone it will expand entities and follow references
  # while rendering. So it has to be readable text, must carry none of
  # `@svg_forbidden`, and may not point a reference at the network or the disk.
  #
  # Deliberately narrower than "contains no URL". Every SVG an editor exports
  # names URLs that are never fetched — the `xmlns` namespaces, and the RDF /
  # Creative-Commons metadata Inkscape writes — so a blanket URL ban would
  # refuse ordinary logos for no reason a member could see. Only a `href`
  # naming an external scheme is a fetch.
  defp safe_svg?(markup) do
    String.valid?(markup) and
      not Regex.match?(@svg_forbidden, markup) and
      not Regex.match?(@svg_external_ref, markup)
  end

  defp open_svg(path) do
    with {:ok, markup} <- File.read(path), do: open_svg_binary(markup)
  end

  # Two loads, because the intrinsic size the scale factor needs comes from the
  # file itself. Not free — librsvg parses the whole document on load, so the
  # probe is a third of the work at logo sizes — but inherent to vector
  # loading: libvips' own `thumbnail/2` measures the same. An SVG that already
  # declares more than the raster size is scaled *down*, so the pixel budget
  # still bounds what a 30000px viewBox can cost us.
  defp open_svg_binary(markup) do
    with :ok <- vet_svg(markup),
         {:ok, {probe, _flags}} <- Operation.svgload_buffer(markup),
         {:ok, {image, _flags}} <- Operation.svgload_buffer(markup, scale: svg_scale(probe)),
         :ok <- within_pixel_budget(image) do
      {:ok, image}
    end
  end

  defp vet_svg(markup), do: if(safe_svg?(markup), do: :ok, else: {:error, :unsafe_svg})

  defp svg_scale(probe) do
    case max(Image.width(probe), Image.height(probe)) do
      edge when edge > 0 -> svg_raster_size() / edge
      _ -> 1.0
    end
  end

  @doc """
  A **link-preview JPEG** derived from the file at `path`: decode and
  EXIF-autorotate, hand the image to `shape` (the per-store geometry — a square
  crop, the member's own crop, a width cap), then save it stripped.
  `:error` when anything on the way fails.

  Open Graph scrapers do not decode the AVIF versions we serve, so every store
  that has a preview endpoint derives one of these. What must not be per-store
  is the last step: `keep: []` is a privacy rule, not a setting — the original's
  camera and GPS metadata may never leave in a served derivative — and it was
  written out in three uploaders, each free to forget it.

  `shape` is a `image -> {:ok, image} | any` fun; anything but `{:ok, _}` ends
  as `:error`.
  """
  def og_jpeg(path, shape) when is_binary(path) and is_function(shape, 1) do
    with {:ok, rotated} <- open_rotated(path),
         {:ok, shaped} <- shape.(rotated),
         {:ok, data} <- Operation.jpegsave_buffer(shaped, keep: [], Q: 80) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  @doc """
  `open_rotated/1` for image bytes already in memory — same pixel budget and
  EXIF autorotation, but keyed on the **content**, not a filename.

  This is the cache-safe decode the AI image scan must use. libvips memoizes
  file loads by their *filename*, and avatar/cover originals live at a fixed
  path (`originals/<id>/original.<ext>`) that a re-upload overwrites in place —
  so decoding that path *by name* returns the FIRST image ever loaded there for
  the whole process lifetime. A member could upload a benign avatar (approved,
  now cached) then swap in an unsafe one, and the re-scan would judge the stale
  safe pixels and release the unsafe image. Decoding from the bytes sidesteps
  the filename cache entirely (`Vutuv.Moderation.Ollama`).

  SVG markup is rasterised and vetted here exactly as in `open_rotated/1`, and
  for the same reason: bytes reach this door from a remote server too (a
  fediverse attachment via `Vutuv.RemoteMedia`, a cover from Open Library), and
  libvips would hand any of them to the SVG renderer on content alone.
  """
  def open_rotated_binary(binary) when is_binary(binary) do
    if svg_binary?(binary) do
      open_svg_binary(binary)
    else
      with {:ok, image} <- Image.from_binary(binary),
           :ok <- within_pixel_budget(image),
           {:ok, {rotated, _flags}} <- Image.autorotate(image) do
        {:ok, rotated}
      end
    end
  end

  defp within_pixel_budget(image) do
    if Image.width(image) * Image.height(image) > @max_megapixels * 1_000_000 do
      {:error, :too_large}
    else
      :ok
    end
  end

  @doc """
  Resizes the (already rotated) `image` per the version `spec` and writes it
  to `dest` as metadata-stripped AVIF. Returns `:ok` or `{:error, reason}`.
  """
  def write_derived(%{fit: fit, quality: quality}, image, dest) do
    with {:ok, resized} <- resize(image, fit) do
      save(resized, dest, quality)
    end
  end

  @doc """
  Writes the **pixelated preview** of an already-rotated `image` to `dest`: the picture
  reduced to #{@pixelated_cells} cells on its longest edge and blown back up with
  each cell as a flat block (issue #1720).

  This is what stands in for a photo while the AI scan is still looking at it
  (`Vutuv.Moderation.Pixelation`), and the reason it is a **file** and not a CSS
  filter is that a filter is one devtools click away from the picture
  underneath. Here the discarded pixels are gone before anything is served:
  the shrink averages them away, and no amount of client-side work gets them
  back.

  `Vix.Vips.Operation.zoom/3` does the blowing up rather than a resize with a
  nearest-neighbour kernel: it replicates each pixel by an integer factor, so
  every block is exactly the same size and the result cannot pick up the
  half-pixel interpolation seams a scaled resample leaves along cell edges.
  The factor is chosen so the long edge lands near #{@pixelated_width}px — a
  #{@pixelated_cells}-cell AVIF blown up to that size is a couple of kilobytes,
  and blowing it
  up here rather than in the browser means the tile looks the same whatever
  `image-rendering` the reader's browser defaults to.
  """
  def write_pixelated(image, dest) do
    with {:ok, small} <-
           Image.thumbnail(image, "#{@pixelated_cells}x#{@pixelated_cells}", resize: :down),
         {:ok, blocky} <- blow_up(small) do
      save(blocky, dest, @pixelated_quality)
    end
  end

  defp blow_up(small) do
    factor = max(1, div(@pixelated_width, max(Image.width(small), Image.height(small))))

    if factor == 1, do: {:ok, small}, else: Operation.zoom(small, factor, factor)
  end

  @doc """
  Writes every version of image `type` from the already-rotated `image`,
  placing each at `dest_fun.(spec)`. Stops at the first failure. Returns `:ok`
  or `{:error, reason}` — the one home of the derive-all halt-on-error loop the
  avatar/cover and post-image stores share.
  """
  def write_all(type, image, dest_fun) when is_function(dest_fun, 1) do
    Enum.reduce_while(versions(type), :ok, fn spec, :ok ->
      case write_derived(spec, image, dest_fun.(spec)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resize(image, {:crop, width, height, gravity}) do
    Image.thumbnail(image, "#{width}x#{height}", crop: gravity)
  end

  # Square, and never bigger than the source. `crop: gravity` alone upscales a
  # smaller source; `resize: :down` beside it stops the upscale but then skips
  # the crop entirely (a 300x200 source comes back 300x199, measured), so the
  # framing would differ from the square versions beside it. Picking the target
  # from the shorter side keeps both promises with the one code path: the
  # crop-to-cover scale is never above 1, so vips crops without ever scaling up.
  defp resize(image, {:crop_down, size, gravity}) do
    side = min(Image.width(image), Image.height(image))
    target = min(side, size)
    Image.thumbnail(image, "#{target}x#{target}", crop: gravity)
  end

  # resize: :down so a smaller upload keeps its native size instead of
  # being blurrily upscaled.
  defp resize(image, {:box_down, size}) do
    Image.thumbnail(image, "#{size}x#{size}", resize: :down)
  end

  defp resize(image, {:width_down, width}) do
    Image.thumbnail(image, "#{width}", resize: :down)
  end

  defp save(image, dest, quality) do
    case Operation.heifsave(image, dest,
           compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1,
           Q: quality,
           effort: @effort,
           keep: []
         ) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
