defmodule Vutuv.PressKitStore do
  @moduledoc """
  On-disk storage for press-kit pictures (issue #2083) — the
  `Vutuv.PostImageStore` pattern, with the one difference the feature exists
  for: here the **original is the point**. A journalist downloads the file a
  printer can use, so the derived AVIF versions are only what the page shows.

      <uploads_dir_prefix>/press_kit/<token>/thumb.avif /lite.avif /feed.avif
                                            /large.avif /xl.avif      (a photo)
      <uploads_dir_prefix>/press_kit/<token>/thumb.avif /large.avif   (a logo)
      <uploads_dir_prefix>/originals/press_kit/<token>/original.<ext>
                                                      /cleaned.<ext>
                                                      /download.png

  There is no public tree: every byte goes through
  `VutuvWeb.PressKitImageController`, which asks
  `Vutuv.PressKit.visible_to?/2` first. Since production serves proxied images
  with `send_file` rather than the X-Accel handoff (`:post_image_serving`,
  `config/runtime.exs`), a new kind of proxied picture costs no nginx change at
  all; `accel_path/2` exists so the mode that is still in the controller keeps
  working if it is ever re-enabled.

  ## What may be uploaded, and why the whitelist is narrower than the decoder's

  A **photo** may be JPEG, PNG or WebP — exactly the containers
  `Vutuv.Uploads.MetadataStrip` can take apart. That is not a coincidence, it is
  the rule: the download hands out the original bytes, so the format has to be
  one whose metadata we can remove with certainty. HEIC is deliberately absent
  even on a build that can decode it (`Vutuv.PostImageStore.heic_supported?/0`),
  because the stripper answers `:unsupported` for it and a press photo nobody
  can clean is a press photo that leaks a GPS fix.

  A **logo** may be SVG or PNG. The SVG is what a designer actually holds, and
  vutuv rasterises every SVG rather than serving one — so the vector leaves only
  through `download_file/1`, as an attachment, beside the PNG rendering
  `png_download_file/1` derives from the same vetted raster. SVG only counts
  when the running libvips can rasterise one (`Vutuv.Uploads.Spec.svg_supported?/0`),
  like the organization logo it sits beside.
  """

  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @photo_extensions ~w(.jpg .jpeg .png .webp)
  @logo_raster_extensions ~w(.png)
  @svg_extensions ~w(.svg)

  # Read off `Vutuv.Uploads.Spec` at compile time rather than written out beside
  # it. A hand-kept second list is how the organization store came to derive an
  # `xl` version no URL of its own could ever serve — it paid for the most
  # expensive AVIF encode of the four and kept the file for ever — and this
  # store is the one with **two** Spec keys, so it would have had two chances.
  @photo_versions Enum.map(Spec.versions(:press_kit), &to_string(&1.name))
  @logo_versions Enum.map(Spec.versions(:press_kit_logo), &to_string(&1.name))
  @all_versions Enum.uniq(@photo_versions ++ @logo_versions)

  @doc """
  What a press **photo** may be uploaded as: exactly the containers
  `Vutuv.Uploads.MetadataStrip` can take apart, because the download is the
  cleaned original and a format we cannot clean is one we cannot hand out.
  """
  def photo_extensions, do: @photo_extensions

  @doc """
  What a **logo variant** may be uploaded as: a PNG, plus SVG where this build
  rasterises one. A vector is what a press kit is asked for, so it is offered
  wherever librsvg is there to render the preview.
  """
  def logo_extensions do
    @logo_raster_extensions ++ if Spec.svg_supported?(), do: @svg_extensions, else: []
  end

  @doc "The whitelist for a shelf: `true` for a logo variant, `false` for a photo."
  def extension_whitelist(true), do: logo_extensions()
  def extension_whitelist(false), do: photo_extensions()

  @doc """
  The served version names of a shelf — the proxy's URL whitelist. A logo has
  two: nothing crops it, and no lightbox blows a wordmark up to 2560px.
  """
  def versions(true), do: @logo_versions
  def versions(false), do: @photo_versions
  def versions(%ImageRow{} = image), do: versions(ImageRow.logo?(image))

  @doc """
  Stores every served version of the file at `path` under a fresh `token`
  directory, keeps the upload verbatim in the private originals tree, and
  returns `{:ok, %{width:, height:, content_type:, size_bytes:}}` (dimensions
  post-rotation) or `{:error, :invalid_file}`.

  `size_bytes` is the **upload's** size, not a derived version's: it is what the
  section page tells a journalist they are about to download.
  """
  def store(path, filename, token, logo?) do
    dir = dir(token)

    Vutuv.Uploads.store_upload(filename, extension_whitelist(logo?), dir, fn ext ->
      write_versions(path, ext, dir, token, logo?)
    end)
  end

  defp write_versions(path, ext, dir, token, logo?) do
    with {:ok, rotated} <- Spec.open_rotated(path),
         :ok <- write_derived_versions(rotated, dir, logo?) do
      # The stand-in a stranger meets while the model looks at this picture
      # (issue #1720). Deliberately outside `write_derived_versions/3`, which
      # the Regenerator also drives: a mosaic is not a version of the picture,
      # it is the temporary absence of one. A vector logo gets one too — it is
      # cut from the rasterisation `open_rotated/1` already made, which is the
      # same door the scan judges it through.
      Pixelation.write_if_enabled(rotated, dir)
      :ok = Originals.store(storage_dir(token), path, ext)

      {:ok,
       %{
         width: Image.width(rotated),
         height: Image.height(rotated),
         size_bytes: File.stat!(path).size
       }}
    end
  end

  defp write_derived_versions(rotated, dir, logo?) do
    Spec.write_all(spec_type(logo?), rotated, fn spec ->
      Path.join(dir, "#{spec.name}#{Spec.served_ext()}")
    end)
  end

  defp spec_type(true), do: :press_kit_logo
  defp spec_type(false), do: :press_kit

  @doc """
  Re-derives every served version from the kept original — the Regenerator's
  hook, so a format or quality change in `Vutuv.Uploads.Spec` reaches press
  pictures too. Takes the row, because which versions are canonical depends on
  the shelf it is on.
  """
  def regenerate(%ImageRow{token: token} = image, opts \\ []) do
    logo? = ImageRow.logo?(image)
    dir = dir(token)

    Vutuv.Uploads.regenerate_from_original(storage_dir(token), dir,
      canonical: canonical_filenames(logo?),
      stale_glob: "*",
      # Nothing here predates the private originals tree: this kind was born
      # after it, so there is no public layout to adopt an original out of.
      legacy_candidates: [],
      derive: &write_derived_versions(&1, dir, logo?),
      opts: opts
    )
  end

  defp canonical_filenames(logo?) do
    for version <- versions(logo?), do: "#{version}#{Spec.served_ext()}"
  end

  @doc "Absolute on-disk path of a served version, or `nil` when missing."
  def version_path(token, version) when is_binary(token) and version in @all_versions do
    avif = Path.join(dir(token), "#{version}#{Spec.served_ext()}")
    if File.exists?(avif), do: avif
  end

  def version_path(_token, _version), do: nil

  @doc """
  Where this picture's stand-in lives (`Vutuv.Moderation.Pixelation`). The path
  is built whether or not the file is there — `Pixelation.stands_in?/2` is what
  asks that, because a missing stand-in is an ordinary state (a settled scan, a
  swept leftover, an installation with the preview switched off). Same contract
  as `Vutuv.PostImageStore.pixelated_path/1`, so the two cannot drift.
  """
  def pixelated_path(token) when is_binary(token), do: Pixelation.path(dir(token))

  @doc """
  Drops the stand-in once the scan has settled. Approval and rejection both end
  the wait it stood in for; a rejection takes the whole directory anyway, which
  makes this the approval's job.
  """
  def delete_pixelated(token) when is_binary(token), do: Pixelation.clear(dir(token))

  @doc """
  Moves every stored file of this picture into its takedown hold, and back
  (`Vutuv.Images.freeze/1` and `unfreeze/1`, issue #2012). Keyed by the row's id
  like every other hold, while the files themselves are keyed by the token —
  which is why these take the row rather than a token.
  """
  def hold(%ImageRow{id: id, token: token}), do: Vutuv.Uploads.hold(id, storage_dir(token))

  def release(%ImageRow{id: id, token: token}), do: Vutuv.Uploads.release(id, storage_dir(token))

  @doc "The X-Accel-Redirect target for a served version, for the mode that uses it."
  def accel_path(token, version) when is_binary(token) and version in @all_versions do
    "/internal_press_kit/#{token}/#{version}#{Spec.served_ext()}"
  end

  @doc """
  The file a journalist downloads, as `{path, ext}`, or `nil` when there is
  nothing safe to hand out.

  A **photo** is always the cleaned copy: the same pixels with every metadata
  block removed (`Vutuv.Uploads.MetadataStrip`), derived once on first request
  and cached beside the original. There is no "exact file" choice the way a post
  photo has one (`download_exact`) — a picture published *for redistribution*
  should not be the one place a camera serial number or a GPS fix leaves, and
  nobody downloading a press photo wants either.

  A **vector logo** is the SVG itself. The stripper cannot take XML apart and
  there is nothing in it to take apart: the markup is what the designer wrote
  and what they released, and it was vetted at upload
  (`Vutuv.Uploads.Spec.open_rotated/1` refuses a document with a DOCTYPE, a
  script, a `foreignObject` or an external reference). It leaves as an
  attachment with `nosniff` — see the controller — because an SVG rendered
  inline on our own origin is a script on our own origin.

  It **fails closed**: a format the stripper cannot clean yields `nil` rather
  than the untouched file. The upload whitelist already makes that unreachable
  for both shelves; it is here because "the download is always clean" is a
  promise, and a promise with no second line is a comment.
  """
  def download_file(%ImageRow{token: token} = image) do
    case Originals.path(storage_dir(token)) do
      nil -> nil
      original -> download_file(original, Path.extname(original), token, ImageRow.logo?(image))
    end
  end

  defp download_file(original, ".svg", _token, true), do: {original, ".svg"}

  defp download_file(original, ext, token, _logo?),
    do: Originals.cleaned_copy(storage_dir(token), original, ext)

  @doc """
  The **PNG rendering** of a logo variant, as `{path, ext}` — what stands beside
  the vector for whoever cannot use one, and what the section page offers as the
  second link on every logo.

  For a logo uploaded as PNG this is its cleaned original: re-encoding a raster
  that is already the right format would only lose pixels. For an SVG it is the
  vetted rasterisation at `Vutuv.Uploads.Spec.svg_raster_size/0`, derived once
  and cached beside the original, saved with `keep: []` like every other file
  that leaves here.

  `nil` for a press photo, which has no such thing, and for a logo whose
  original is gone.
  """
  def png_download_file(%ImageRow{logo: true, token: token}) do
    case Originals.path(storage_dir(token)) do
      nil -> nil
      original -> png_download(original, Path.extname(original), token)
    end
  end

  def png_download_file(%ImageRow{}), do: nil

  # A logo already stored as PNG is handed over as its cleaned self: re-encoding
  # a raster that is already the right format would only lose pixels.
  defp png_download(original, ".png" = ext, token),
    do: Originals.cleaned_copy(storage_dir(token), original, ext)

  defp png_download(original, _vector, token) do
    dest = Path.join(Originals.dir(storage_dir(token)), "download.png")

    if File.exists?(dest) do
      {dest, ".png"}
    else
      case Spec.raster_png(original) do
        {:ok, bytes} -> {Originals.publish(dest, bytes), ".png"}
        :error -> nil
      end
    end
  end

  @doc "Absolute path of the kept private original, or `nil` when there is none."
  def original_path(token) when is_binary(token), do: Originals.path(storage_dir(token))
  def original_path(_token), do: nil

  @doc "Removes every stored file of `token`. A no-op when nothing is stored."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    Originals.delete(storage_dir(token))
    :ok
  end

  def delete(_token), do: :ok

  defp storage_dir(token) do
    # The token is Base64-URL ([A-Za-z0-9_-]) by construction, but never trust a
    # stored value enough to build paths with separators in it.
    false = String.contains?(token, ["/", ".."])
    Path.join("press_kit", token)
  end

  defp dir(token), do: Vutuv.Uploads.disk_dir(storage_dir(token))
end
