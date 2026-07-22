defmodule Vutuv.QualificationDocument do
  @moduledoc """
  On-disk storage for the proof document a member may attach to a certificate
  or license (`Vutuv.Profiles.Qualification`): a PDF or an image of the
  credential, publicly viewable and downloadable — the member consents to
  exactly that at upload time (the changeset refuses the file otherwise).

  Like post images there is **no public tree**: every byte goes through the
  authorizing proxy (`VutuvWeb.QualificationDocumentController`), which is how
  a document still in moderation limbo stays owner-only. Layout, keyed by the
  qualification's id:

      <uploads_dir_prefix>/qualification_documents/<id>/thumb.avif
                                                       /document.<ext>
      <uploads_dir_prefix>/originals/qualification_documents/<id>/original.<ext>
                                                                 /scan_page.jpg  (PDF only)

  `document.<ext>` is the **public copy** the download serves: a PDF verbatim;
  an image re-encoded metadata-stripped (`keep: []`), so the download can never
  leak the original's EXIF/GPS. The verbatim original stays in the private
  `originals/` tree (never served, house rule) as the re-derive and moderation
  source. For a PDF the moderation source is `scan_page.jpg` — the first page
  rendered at upload time — because the vision model cannot decode a PDF.

  PDF rendering shells out to `pdftoppm` (poppler-utils), **capability-
  detected** like HEIC in `Vutuv.PostImageStore`: on a host without it, `.pdf`
  drops out of the extension whitelist and `validate/1` answers
  `{:error, :pdf_unsupported}`, so members get a clear message while image
  uploads keep working (see docs/ADMINS.md).
  """

  require Logger

  alias Vix.Vips.Operation
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @image_extensions ~w(.jpg .jpeg .png .webp)
  @pdf_extensions ~w(.pdf)

  # 10 MB — generous for a scanned certificate, small enough that a profile
  # page of thumbnails stays cheap to build.
  @max_size 10_000_000

  @doc "The maximum accepted upload size in bytes."
  def max_size, do: @max_size

  @doc """
  The accepted extensions: images always (plus HEIC when the libvips build can
  decode it), `.pdf` only when `pdftoppm` is available on this host.
  """
  def extension_whitelist do
    heic = if Vutuv.PostImageStore.heic_supported?(), do: ~w(.heic .heif), else: []
    pdf = if pdf_supported?(), do: @pdf_extensions, else: []
    @image_extensions ++ heic ++ pdf
  end

  @doc """
  Whether this host can render PDFs (`pdftoppm` from poppler-utils on
  `$PATH`). Probed once, cached for the VM's lifetime.
  """
  def pdf_supported? do
    case :persistent_term.get({__MODULE__, :pdf_supported}, :unknown) do
      :unknown ->
        supported = System.find_executable("pdftoppm") != nil
        :persistent_term.put({__MODULE__, :pdf_supported}, supported)
        supported

      verdict ->
        verdict
    end
  end

  @doc """
  The pre-commit check (`Vutuv.Uploads.valid_upload?/1` pattern): extension,
  size and a real decode — a PDF is rendered to prove it can be, an image is
  opened — **without writing into the storage tree**. Distinguishes
  `{:error, :pdf_unsupported}` (this installation cannot take PDFs) from
  `{:error, :invalid_file}` / `{:error, :too_large}` so the form can say why.
  """
  def validate(%Plug.Upload{} = upload) do
    ext = extension(upload.filename)

    cond do
      ext == ".pdf" and not pdf_supported?() -> {:error, :pdf_unsupported}
      ext not in extension_whitelist() -> {:error, :invalid_file}
      File.stat!(upload.path).size > @max_size -> {:error, :too_large}
      true -> validate_decodes(upload.path, ext)
    end
  end

  def validate(_other), do: {:error, :invalid_file}

  defp validate_decodes(path, ".pdf") do
    with_rendered_page(path, fn _page -> :ok end)
  end

  defp validate_decodes(path, _ext) do
    case Spec.open_rotated(path) do
      {:ok, _image} -> :ok
      {:error, _} -> {:error, :invalid_file}
    end
  end

  @doc """
  Stores the document for `qualification_id`, replacing any prior one, and
  returns `{:ok, %{fingerprint:, content_type:, size:}}` or `{:error, reason}`
  (same classes as `validate/1`). The fingerprint hashes the **original**
  bytes; `content_type`/`size` describe the public copy the download serves
  (they differ from the original only for a HEIC, which is served as JPEG).
  """
  def store(%Plug.Upload{} = upload, qualification_id) do
    ext = extension(upload.filename)

    cond do
      ext == ".pdf" and not pdf_supported?() -> {:error, :pdf_unsupported}
      ext not in extension_whitelist() -> {:error, :invalid_file}
      File.stat!(upload.path).size > @max_size -> {:error, :too_large}
      true -> write_all(upload, ext, qualification_id)
    end
  end

  defp write_all(upload, ".pdf", qualification_id) do
    with_rendered_page(upload.path, fn page ->
      with {:ok, rotated} <- Spec.open_rotated(page),
           :ok <- prepare_dir(qualification_id),
           :ok <- write_thumb(rotated, qualification_id),
           :ok <- copy_public(upload.path, ".pdf", qualification_id),
           :ok <- Originals.store(storage_dir(qualification_id), upload.path, ".pdf"),
           :ok <- keep_scan_page(page, qualification_id) do
        {:ok, meta(upload, qualification_id)}
      else
        {:error, _reason} -> cleanup_failed(qualification_id)
      end
    end)
  end

  defp write_all(upload, ext, qualification_id) do
    with {:ok, rotated} <- Spec.open_rotated(upload.path),
         :ok <- prepare_dir(qualification_id),
         :ok <- write_thumb(rotated, qualification_id),
         :ok <- write_public_image(rotated, ext, qualification_id),
         :ok <- Originals.store(storage_dir(qualification_id), upload.path, ext) do
      {:ok, meta(upload, qualification_id)}
    else
      {:error, _reason} -> cleanup_failed(qualification_id)
    end
  end

  defp meta(upload, qualification_id) do
    public = file_path(qualification_id)

    %{
      fingerprint: Uploads.content_hash(upload.path),
      content_type: MIME.from_path(public),
      size: File.stat!(public).size
    }
  end

  # A half-written replacement must not leave a mixed state behind: the old
  # files are already cleared, so remove everything and report the file bad.
  defp cleanup_failed(qualification_id) do
    delete(qualification_id)
    {:error, :invalid_file}
  end

  defp prepare_dir(qualification_id) do
    dir = dir(qualification_id)
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    :ok
  end

  defp write_thumb(rotated, qualification_id) do
    Spec.write_all(:qualification_document, rotated, fn spec ->
      Path.join(dir(qualification_id), "#{spec.name}#{Spec.served_ext()}")
    end)
  end

  # The public copy of a PDF is the PDF itself (that is the document).
  defp copy_public(source, ext, qualification_id) do
    File.cp!(source, Path.join(dir(qualification_id), "document#{ext}"))
    :ok
  end

  # The public copy of an image: re-encoded in its own format family with
  # `keep: []`, so the download carries no EXIF/GPS. HEIC becomes JPEG —
  # browsers cannot display HEIC anyway.
  defp write_public_image(rotated, ext, qualification_id) do
    dest = fn e -> Path.join(dir(qualification_id), "document#{e}") end

    result =
      case ext do
        ".png" -> Operation.pngsave(rotated, dest.(".png"), keep: [])
        ".webp" -> Operation.webpsave(rotated, dest.(".webp"), keep: [], Q: 92)
        _jpeg_or_heic -> Operation.jpegsave(rotated, dest.(".jpg"), keep: [], Q: 92)
      end

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Renders page 1 of the PDF into a temp JPEG (150 dpi — crisp enough for the
  # 640px thumb) and hands its path to `fun`; the temp files are removed
  # afterwards. `{:error, :invalid_file}` when poppler cannot read the PDF
  # (corrupt, encrypted).
  defp with_rendered_page(pdf_path, fun) do
    base = Path.join(System.tmp_dir!(), "qdoc_page_#{System.unique_integer([:positive])}")

    try do
      case System.cmd(
             "pdftoppm",
             ["-f", "1", "-l", "1", "-r", "150", "-jpeg", pdf_path, base],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          case Path.wildcard(base <> "*") do
            [page | _] -> fun.(page)
            [] -> {:error, :invalid_file}
          end

        {out, status} ->
          Logger.info("pdftoppm failed (#{status}): #{String.slice(out, 0, 200)}")
          {:error, :invalid_file}
      end
    after
      for file <- Path.wildcard(base <> "*"), do: File.rm(file)
    end
  end

  @doc "Absolute path of the stored thumbnail, or nil."
  def thumb_path(qualification_id) do
    existing(Path.join(dir(qualification_id), "thumb#{Spec.served_ext()}"))
  end

  @doc "Absolute path of the public copy (`document.<ext>`), or nil."
  def file_path(qualification_id) do
    dir(qualification_id)
    |> Path.join("document.*")
    |> Path.wildcard()
    |> List.first()
  end

  @doc """
  The file the AI image scan judges (`Vutuv.Moderation.ImageSubjects`): the
  rendered PDF page when one exists, else the verbatim original. nil when
  nothing is stored.
  """
  def scan_source_path(qualification_id) do
    scan_page(qualification_id) || Originals.path(storage_dir(qualification_id))
  end

  defp scan_page(qualification_id) do
    case Originals.path(storage_dir(qualification_id)) do
      nil -> nil
      original -> existing(Path.join(Path.dirname(original), "scan_page.jpg"))
    end
  end

  defp keep_scan_page(page, qualification_id) do
    original = Originals.path(storage_dir(qualification_id))
    File.cp!(page, Path.join(Path.dirname(original), "scan_page.jpg"))
    :ok
  end

  @doc """
  The public copy's extension for a stored content type — the one source for
  the proxy URL (`<fingerprint><ext>`) and the route parser, so the two can
  never disagree. Deterministic on purpose (`MIME.extensions/1` order is not
  ours to rely on).
  """
  def public_ext("application/pdf"), do: ".pdf"
  def public_ext("image/png"), do: ".png"
  def public_ext("image/webp"), do: ".webp"
  def public_ext(_jpeg_or_unknown), do: ".jpg"

  @doc "Removes every stored file. A no-op when nothing is stored."
  def delete(qualification_id) do
    File.rm_rf(dir(qualification_id))
    Originals.delete(storage_dir(qualification_id))
    :ok
  end

  @doc """
  Re-derives the thumbnail from the kept source per the current Spec (the
  regenerator hook): the rendered PDF page or the original image. `:unchanged`
  when nothing is stored or the thumb is already present, `{:skipped,
  :missing_original}` when only the thumb is gone but no source remains.
  """
  def regenerate(qualification_id, opts \\ []) do
    source = scan_source_path(qualification_id)

    cond do
      is_nil(Originals.path(storage_dir(qualification_id))) ->
        :unchanged

      thumb_path(qualification_id) != nil and not Keyword.get(opts, :force, false) ->
        :unchanged

      is_nil(source) ->
        {:skipped, :missing_original}

      true ->
        with {:ok, rotated} <- Spec.open_rotated(source) do
          File.mkdir_p!(dir(qualification_id))
          write_thumb(rotated, qualification_id)
        end
    end
  end

  defp existing(path), do: if(File.exists?(path), do: path)

  defp extension(filename), do: filename |> Path.extname() |> String.downcase()

  defp storage_dir(qualification_id) do
    # The id is a UUID by construction, but never trust a stored value enough
    # to build paths with separators in it.
    id = to_string(qualification_id)
    false = String.contains?(id, ["/", ".."])
    Path.join("qualification_documents", id)
  end

  defp dir(qualification_id), do: Uploads.disk_dir(storage_dir(qualification_id))
end
