defmodule Vutuv.JobReferenceDocument do
  @moduledoc """
  On-disk storage for the Arbeitszeugnis a member uploads
  (`Vutuv.References.JobReference`): a PDF or an image of the document.

  The `Vutuv.QualificationDocument` layout, with one difference that matters:
  a qualification's proof is public by the time it is stored, while a Zeugnis
  is **private by default**. Nothing here is served by nginx; every byte goes
  through `VutuvWeb.JobReferenceDocumentController`, which checks the entry's
  own `public?` flag and its moderation state on each request.

      <uploads_dir_prefix>/job_reference_documents/<id>/thumb.avif
                                                       /page.avif
                                                       /document.<ext>
      <uploads_dir_prefix>/originals/job_reference_documents/<id>/original.<ext>
                                                                 /scan_page.jpg  (PDF only)

  `document.<ext>` is the copy the download serves: a PDF verbatim, an image
  re-encoded metadata-stripped (`keep: []`) so it can never leak the
  original's EXIF/GPS. The verbatim original stays in the private `originals/`
  tree — it is both the re-derive source and, for a PDF, what the text
  extraction reads. For a PDF the moderation source is `scan_page.jpg`, page 1
  rendered at upload time, because the vision model cannot decode a PDF.

  PDF handling shells out to poppler-utils and is **capability-detected**: on
  a host without `pdftoppm`, `.pdf` drops out of the whitelist and `validate/1`
  answers `{:error, :pdf_unsupported}`, so the member is told to paste the
  text instead while image uploads keep working.
  """

  require Logger

  alias Vix.Vips.Operation
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @image_extensions ~w(.jpg .jpeg .png .webp)
  @pdf_extensions ~w(.pdf)

  # 10 MB, the qualification-document budget: generous for a scanned multi-page
  # Zeugnis, small enough that a card list of thumbnails stays cheap.
  @max_size 10_000_000

  @doc "The maximum accepted upload size in bytes."
  def max_size, do: @max_size

  @doc """
  The accepted extensions: images always (plus HEIC when libvips can decode
  it), `.pdf` only when this host can render PDFs.
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
  The pre-commit check: extension, size and a real decode, without writing
  into the storage tree. Distinguishes `{:error, :pdf_unsupported}` from
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

  defp validate_decodes(path, ".pdf"), do: with_rendered_page(path, fn _page -> :ok end)

  defp validate_decodes(path, _ext) do
    case Spec.open_rotated(path) do
      {:ok, _image} -> :ok
      {:error, _reason} -> {:error, :invalid_file}
    end
  end

  @doc """
  Stores the document for `reference_id`, replacing any prior one, and returns
  `{:ok, %{fingerprint:, content_type:, size:, page_count:}}` or
  `{:error, reason}` (the `validate/1` classes).

  The fingerprint hashes the **original** bytes; `content_type`/`size`
  describe the copy the download serves, which differs from the original only
  for a HEIC (served as JPEG).
  """
  def store(%Plug.Upload{} = upload, reference_id) do
    ext = extension(upload.filename)

    cond do
      ext == ".pdf" and not pdf_supported?() -> {:error, :pdf_unsupported}
      ext not in extension_whitelist() -> {:error, :invalid_file}
      File.stat!(upload.path).size > @max_size -> {:error, :too_large}
      true -> write_all(upload, ext, reference_id)
    end
  end

  defp write_all(upload, ".pdf", reference_id) do
    with_rendered_page(upload.path, fn page ->
      with {:ok, rotated} <- Spec.open_rotated(page),
           :ok <- prepare_dir(reference_id),
           :ok <- write_versions(rotated, reference_id),
           :ok <- copy_public(upload.path, ".pdf", reference_id),
           :ok <- Originals.store(storage_dir(reference_id), upload.path, ".pdf"),
           :ok <- keep_scan_page(page, reference_id) do
        {:ok, meta(upload, reference_id)}
      else
        {:error, _reason} -> cleanup_failed(reference_id)
      end
    end)
  end

  defp write_all(upload, ext, reference_id) do
    with {:ok, rotated} <- Spec.open_rotated(upload.path),
         :ok <- prepare_dir(reference_id),
         :ok <- write_versions(rotated, reference_id),
         :ok <- write_public_image(rotated, ext, reference_id),
         :ok <- Originals.store(storage_dir(reference_id), upload.path, ext) do
      {:ok, meta(upload, reference_id)}
    else
      {:error, _reason} -> cleanup_failed(reference_id)
    end
  end

  defp meta(upload, reference_id) do
    public = file_path(reference_id)

    %{
      fingerprint: Uploads.content_hash(upload.path),
      content_type: MIME.from_path(public),
      size: File.stat!(public).size,
      page_count: page_count(Originals.path(storage_dir(reference_id)))
    }
  end

  # A half-written replacement must not leave a mixed state behind: the old
  # files are already cleared, so remove everything and report the file bad.
  defp cleanup_failed(reference_id) do
    delete(reference_id)
    {:error, :invalid_file}
  end

  defp prepare_dir(reference_id) do
    dir = dir(reference_id)
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    :ok
  end

  defp write_versions(rotated, reference_id) do
    Spec.write_all(:job_reference_document, rotated, fn spec ->
      Path.join(dir(reference_id), "#{spec.name}#{Spec.served_ext()}")
    end)
  end

  # The public copy of a PDF is the PDF itself (that is the document).
  defp copy_public(source, ext, reference_id) do
    File.cp!(source, Path.join(dir(reference_id), "document#{ext}"))
    :ok
  end

  # The public copy of an image: re-encoded in its own format family with
  # `keep: []`, so the download carries no EXIF/GPS. HEIC becomes JPEG —
  # browsers cannot display HEIC anyway.
  defp write_public_image(rotated, ext, reference_id) do
    dest = fn e -> Path.join(dir(reference_id), "document#{e}") end

    result =
      case ext do
        ".png" -> Operation.pngsave(rotated, dest.(".png"), keep: [])
        ".webp" -> Operation.webpsave(rotated, dest.(".webp"), keep: [], Q: 92)
        _jpeg_or_heic -> Operation.jpegsave(rotated, dest.(".jpg"), keep: [], Q: 92)
      end

    case result do
      :ok -> :ok
      {:ok, _image} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Renders page 1 into a temp JPEG (150 dpi — crisp enough for the 1400px
  # version) and hands its path to `fun`; the temp files are removed
  # afterwards. `{:error, :invalid_file}` when poppler cannot read the PDF.
  defp with_rendered_page(pdf_path, fun) do
    base = Path.join(System.tmp_dir!(), "jrdoc_page_#{System.unique_integer([:positive])}")

    try do
      case System.cmd("pdftoppm", ["-f", "1", "-l", "1", "-r", "150", "-jpeg", pdf_path, base],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          case Path.wildcard(base <> "*") do
            [page | _rest] -> fun.(page)
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

  @doc """
  How many pages the stored PDF has, or nil (not a PDF, or `pdfinfo` missing).

  Cosmetic only — it labels the thumbnail ("3 Seiten"). `pdfinfo` ships in the
  same poppler-utils package as `pdftoppm`, but it is probed anyway rather
  than assumed: a missing page count must never fail an upload.
  """
  def page_count(nil), do: nil

  def page_count(path) do
    with ".pdf" <- extension(path),
         info when is_binary(info) <- System.find_executable("pdfinfo"),
         {out, 0} <- System.cmd(info, [path], stderr_to_stdout: true),
         [_all, count] <- Regex.run(~r/^Pages:\s+(\d+)/m, out) do
      String.to_integer(count)
    else
      _not_available -> nil
    end
  end

  @doc "Absolute path of a stored version (`:thumb` | `:page`), or nil."
  def version_path(reference_id, version) when version in [:thumb, :page] do
    existing(Path.join(dir(reference_id), "#{version}#{Spec.served_ext()}"))
  end

  @doc "Absolute path of the public copy (`document.<ext>`), or nil."
  def file_path(reference_id) do
    dir(reference_id)
    |> Path.join("document.*")
    |> Path.wildcard()
    |> List.first()
  end

  @doc """
  The verbatim original, or nil. This is what the text extraction reads: the
  public copy of a PDF is byte-identical, but for an image it has been
  re-encoded, and OCR should see what the member actually uploaded.
  """
  def original_path(reference_id), do: Originals.path(storage_dir(reference_id))

  @doc """
  The file the AI image scan judges: the rendered PDF page when one exists,
  else the verbatim original. nil when nothing is stored.
  """
  def scan_source_path(reference_id) do
    scan_page(reference_id) || original_path(reference_id)
  end

  defp scan_page(reference_id) do
    case original_path(reference_id) do
      nil -> nil
      original -> existing(Path.join(Path.dirname(original), "scan_page.jpg"))
    end
  end

  defp keep_scan_page(page, reference_id) do
    original = original_path(reference_id)
    File.cp!(page, Path.join(Path.dirname(original), "scan_page.jpg"))
    :ok
  end

  @doc """
  The public copy's extension for a stored content type — the one source for
  the proxy URL (`<fingerprint><ext>`) and the route parser, so the two can
  never disagree.
  """
  def public_ext("application/pdf"), do: ".pdf"
  def public_ext("image/png"), do: ".png"
  def public_ext("image/webp"), do: ".webp"
  def public_ext(_jpeg_or_unknown), do: ".jpg"

  @doc "Removes every stored file. A no-op when nothing is stored."
  def delete(reference_id) do
    File.rm_rf(dir(reference_id))
    Originals.delete(storage_dir(reference_id))
    :ok
  end

  @doc """
  Re-derives the served versions from the kept source per the current Spec
  (the regenerator hook).
  """
  def regenerate(reference_id, opts \\ []) do
    source = scan_source_path(reference_id)

    cond do
      is_nil(original_path(reference_id)) ->
        :unchanged

      version_path(reference_id, :thumb) != nil and not Keyword.get(opts, :force, false) ->
        :unchanged

      is_nil(source) ->
        {:skipped, :missing_original}

      true ->
        with {:ok, rotated} <- Spec.open_rotated(source) do
          File.mkdir_p!(dir(reference_id))
          write_versions(rotated, reference_id)
        end
    end
  end

  defp existing(path), do: if(File.exists?(path), do: path)

  defp extension(filename), do: filename |> Path.extname() |> String.downcase()

  defp storage_dir(reference_id) do
    # The id is a UUID by construction, but never trust a stored value enough
    # to build paths with separators in it.
    id = to_string(reference_id)
    false = String.contains?(id, ["/", ".."])
    Path.join("job_reference_documents", id)
  end

  defp dir(reference_id), do: Uploads.disk_dir(storage_dir(reference_id))
end
