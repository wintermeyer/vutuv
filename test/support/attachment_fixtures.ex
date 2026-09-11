defmodule Vutuv.AttachmentFixtures do
  @moduledoc """
  Files for the attachment tests (issue #2104), **built at run time** rather
  than checked in — the same reasoning as `Vutuv.VideoFixtures`, and stronger
  here: half of these are PDFs carrying JavaScript, an OpenAction or an
  embedded payload, and a repository this public should not hold one even as a
  fixture.

  Each builder writes a minimal but structurally real PDF (one page, one
  font), so `pdfinfo` reads it as a document rather than rejecting it as
  broken. `hidden/2` runs a file through `qpdf --object-streams=generate`,
  which moves every dictionary into a Flate-compressed object stream — the one
  transformation that makes a raw-byte scan for `/JavaScript` come back empty
  while the document still does the same thing.
  """

  @doc "A PDF with nothing in it but a page."
  def plain_pdf(dir), do: write(dir, "plain.pdf", pdf(:plain))

  @doc "A PDF whose catalog carries a document-level JavaScript action."
  def javascript_pdf(dir), do: write(dir, "javascript.pdf", pdf(:javascript))

  @doc "A PDF that performs a URI action when it is opened."
  def open_action_pdf(dir), do: write(dir, "open_action.pdf", pdf(:open_action))

  @doc "A PDF whose OpenAction is a plain destination — what LaTeX and Word write."
  def destination_pdf(dir), do: write(dir, "destination.pdf", pdf(:destination))

  @doc """
  A PDF whose OpenAction *looks* like a destination — `/S /GoTo` — and chains a
  second action behind `/Next` that launches an application. `pdfinfo` answers
  `JavaScript: no`; only naming `/Launch` catches it.
  """
  def chained_launch_pdf(dir), do: write(dir, "chained.pdf", pdf(:chained_launch))

  @doc """
  A PDF with no OpenAction at all: the launch hangs off the page's `/AA /O`,
  which fires on the same event under a different name.
  """
  def page_action_launch_pdf(dir), do: write(dir, "page-action.pdf", pdf(:page_action))

  @doc "A PDF carrying another file inside it."
  def embedded_file_pdf(dir), do: write(dir, "embedded.pdf", pdf(:embedded))

  @doc """
  A PDF encrypted with a user password — `pdfinfo` cannot even open it. Needs
  `qpdf`; returns `nil` when it is not installed (CI carries poppler for the
  gate itself but not qpdf), so a machine without it skips the encryption tests
  rather than failing the suite, the same way `hidden/2` does.
  """
  def encrypted_pdf(dir) do
    encrypt(dir, "encrypted.pdf", ["--user-password=secret", "--owner-password=owner"])
  end

  @doc """
  A PDF with an owner password only: readable by anybody, but restricted, and
  the shape `pdfinfo` answers `Encrypted: yes` for rather than refusing. Needs
  `qpdf`; `nil` without it, as `encrypted_pdf/1`.
  """
  def owner_encrypted_pdf(dir) do
    encrypt(dir, "owner-encrypted.pdf", ["--user-password=", "--owner-password=owner"])
  end

  @doc """
  The same file with every dictionary moved into a compressed object stream.
  Needs `qpdf`; returns `nil` when it is not installed, so a machine without it
  skips the "and the same trick hidden" half rather than failing the suite.
  """
  def hidden(dir, source) do
    dest = Path.join(dir, "hidden-" <> Path.basename(source))

    with qpdf when is_binary(qpdf) <- System.find_executable("qpdf"),
         {_out, 0} <-
           System.cmd(qpdf, ["--object-streams=generate", source, dest], stderr_to_stdout: true) do
      dest
    else
      _no_qpdf -> nil
    end
  end

  @doc """
  An `/OpenAction` that launches something, hidden in an object stream padded
  past `PdfGate`'s per-stream inflation cut. One `qpdf --object-streams=generate`
  over a catalog carrying 9 MB of filler yields a ~10 KB file whose only object
  stream inflates past the cut — so a pass that *skipped* what it could not
  finish reading walked straight past the action. Returns `nil` without qpdf.
  """
  def oversized_object_stream_pdf(dir) do
    padded =
      write(
        dir,
        "padded-source.pdf",
        pdf(:launch_padded)
      )

    dest = Path.join(dir, "padded.pdf")

    with qpdf when is_binary(qpdf) <- System.find_executable("qpdf"),
         {_out, 0} <-
           System.cmd(qpdf, ["--object-streams=generate", "--compress-streams=y", padded, dest],
             stderr_to_stdout: true
           ) do
      File.rm(padded)
      dest
    else
      _no_qpdf -> nil
    end
  end

  @doc """
  A launch action genuinely compressed inside a FlateDecode stream whose
  payload carries the literal bytes `endstream` ahead of it, planted in an
  uncompressed deflate block. `/Launch` is not in the raw file, and a scan that
  ended the stream at the first literal `endstream` would inflate only the
  decoy. Needs no external tool — the deflate stream is assembled here.
  """
  def endstream_decoy_pdf(dir) do
    decoy = "clean content endstream more padding so the scan would stop here"
    real = "/OpenAction << /S /Launch /F (calc.exe) >> plus real bytes to compress"

    # A zlib stream is a 2-byte header, deflate blocks, then a 4-byte adler32.
    # The decoy is a stored (uncompressed) block, so its `endstream` bytes stay
    # literal; the real payload is `:zlib.zip/1`'s raw deflate, whose last block
    # is final. The adler32 of the whole output is lifted off a normal
    # `:zlib.compress/1` so the stream verifies and inflates to decoy <> real.
    full = decoy <> real
    zwrapped = :zlib.compress(full)
    adler = binary_part(zwrapped, byte_size(zwrapped) - 4, 4)

    body = <<0x78, 0x9C>> <> stored_block(decoy) <> :zlib.zip(real) <> adler
    ^full = :zlib.uncompress(body)

    stream = "<< /Length #{byte_size(body)} /Filter /FlateDecode >>\nstream\n#{body}\nendstream"
    write(dir, "endstream-decoy.pdf", pdf(:plain, [{6, stream}]))
  end

  # One uncompressed deflate block (BTYPE 00), never the final one, so a real
  # compressed block can follow it. LEN then its ones-complement, little-endian.
  defp stored_block(payload) do
    len = byte_size(payload)
    <<0, len::little-16, Bitwise.bxor(len, 0xFFFF)::little-16>> <> payload
  end

  @doc "A ZIP file under a `.pdf` name: the extension lies, the bytes do not."
  def zip_named_pdf(dir) do
    # A real (empty) ZIP: the end-of-central-directory record on its own.
    write(dir, "invoice.pdf", "PK\x05\x06" <> :binary.copy(<<0>>, 18))
  end

  @doc """
  A PDF with `count` real pages, each numbered — what #2105's preview
  rendering is measured against, since the cap only shows on a file that has
  more pages than the installation renders.
  """
  def multi_page_pdf(dir, count) when is_integer(count) and count > 0 do
    write(dir, "multi-#{count}.pdf", multi_page(count))
  end

  @doc """
  A PDF carrying its author's name, the software that wrote it and its dates
  in **both** places a PDF keeps them (issue #2107): the trailer's `/Info`
  dictionary and an XMP metadata packet on the catalog. Stripping only one of
  the two leaves the name in the file, which is what makes a fixture with both
  worth building.
  """
  def metadata_pdf(dir), do: write(dir, "metadata.pdf", pdf(:metadata))

  @doc "The name that fixture puts in every metadata field."
  def metadata_author, do: "Erika Mustermann"

  @doc "The software that fixture claims wrote it."
  def metadata_software, do: "SecretWriter 9.1"

  @doc "A plain text file."
  def text_file(dir, body \\ "Just some notes.\nOn two lines.\n"),
    do: write(dir, "notes.txt", body)

  @doc "A Markdown file."
  def markdown_file(dir), do: write(dir, "readme.md", "# Title\n\nA paragraph.\n")

  @doc "A file of `bytes` zero bytes under a `.txt` name."
  def sized_file(dir, bytes, name \\ "big.txt"),
    do: write(dir, name, :binary.copy("a", bytes))

  @doc """
  A throwaway uploads root for one test, pointed at by `:uploads_dir_prefix`
  and removed on exit, plus the `files/` directory the fixtures are built in.
  Answers `%{tmp:, files:}`, so a `setup` block merges it straight into the
  context. Every attachment suite needs the same five lines; this is them.
  """
  def tmp_uploads_dir do
    tmp = Path.join(System.tmp_dir!(), "vutuv_uploads_#{System.unique_integer([:positive])}")
    files = Path.join(tmp, "files")
    File.mkdir_p!(files)
    Vutuv.WebPushHelpers.put_config(:uploads_dir_prefix, tmp)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, files: files}
  end

  @doc """
  Sets keys of `:attachments` for the rest of the test module (restored on
  exit), the twin of `Vutuv.VideoFixtures.put_video_config/2`. The keys are read
  by the chokepoint, the composer and the sweeper alike, so the module must be
  `async: false`.
  """
  def put_config(overrides) when is_list(overrides) do
    Vutuv.WebPushHelpers.put_config(
      :attachments,
      Keyword.merge(Application.fetch_env!(:vutuv, :attachments), overrides)
    )
  end

  defp encrypt(dir, name, args) do
    case System.find_executable("qpdf") do
      nil ->
        nil

      qpdf ->
        source = plain_pdf(dir)
        dest = Path.join(dir, name)

        {out, status} =
          System.cmd(qpdf, ["--encrypt"] ++ args ++ ["--bits=256", "--", source, dest],
            stderr_to_stdout: true
          )

        if status != 0, do: raise("qpdf could not encrypt the fixture (#{status}): #{out}")
        dest
    end
  end

  defp write(dir, name, bytes) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  ## The PDFs themselves

  @content "BT /F1 24 Tf 72 700 Td (hello) Tj ET"

  defp pdf(kind, more \\ []) do
    {root, extra} = catalog(kind)

    build(
      [
        {1, root},
        {2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"},
        {3, page(kind)},
        {4, "<< /Length #{byte_size(@content)} >>\nstream\n#{@content}\nendstream"},
        {5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
        | extra
      ] ++ more,
      trailer_extra(kind)
    )
  end

  # Only the metadata fixture needs anything past /Root in the trailer.
  defp trailer_extra(:metadata), do: " /Info 7 0 R"
  defp trailer_extra(_kind), do: ""

  # The page dictionary. `:page_action` hangs an additional action off it, which
  # is where a launch goes when there is no `/OpenAction` to put it in.
  defp page(:page_action) do
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " <>
      "/AA << /O << /S /Launch /F (calc.exe) >> >> " <>
      "/Resources << /Font << /F1 5 0 R >> >> >>"
  end

  defp page(_kind) do
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " <>
      "/Resources << /Font << /F1 5 0 R >> >> >>"
  end

  # A document of `count` pages, each with its own content stream saying which
  # page it is, so a rendered preview can be told from its neighbours. Object
  # numbers: 1 catalog, 2 the page tree, 3 the shared font, then a page and a
  # content object per page.
  defp multi_page(count) do
    pages = for index <- 0..(count - 1), do: {4 + index * 2, 5 + index * 2}
    kids = Enum.map_join(pages, " ", fn {page, _content} -> "#{page} 0 R" end)

    page_objects =
      Enum.flat_map(Enum.with_index(pages, 1), fn {{page, content}, number} ->
        text = "BT /F1 96 Tf 72 400 Td (#{number}) Tj ET"

        [
          {page,
           "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents #{content} 0 R " <>
             "/Resources << /Font << /F1 3 0 R >> >> >>"},
          {content, "<< /Length #{byte_size(text)} >>\nstream\n#{text}\nendstream"}
        ]
      end)

    build(
      [
        {1, "<< /Type /Catalog /Pages 2 0 R >>"},
        {2, "<< /Type /Pages /Kids [#{kids}] /Count #{count} >>"},
        {3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
      ] ++ page_objects
    )
  end

  defp catalog(:plain), do: {"<< /Type /Catalog /Pages 2 0 R >>", []}

  defp catalog(:javascript) do
    {"<< /Type /Catalog /Pages 2 0 R /Names << /JavaScript << /Names [(a) 6 0 R] >> >> >>",
     [{6, "<< /S /JavaScript /JS (app.alert\\(1\\);) >>"}]}
  end

  defp catalog(:open_action) do
    {"<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /URI /URI (https://example.com) >> >>", []}
  end

  defp catalog(:destination) do
    {"<< /Type /Catalog /Pages 2 0 R /OpenAction [3 0 R /FitH 800] >>", []}
  end

  defp catalog(:chained_launch) do
    {"<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /GoTo /D [3 0 R /Fit] " <>
       "/Next << /S /Launch /F (calc.exe) >> >> >>", []}
  end

  defp catalog(:page_action), do: {"<< /Type /Catalog /Pages 2 0 R >>", []}

  # The author's name, the software and the dates, in both of the two places a
  # PDF keeps them: the XMP packet hanging off the catalog (object 6) and the
  # /Info dictionary the trailer points at (object 7).
  defp catalog(:metadata) do
    xmp = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
    xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:xmp="http://ns.adobe.com/xap/1.0/">
    <dc:creator><rdf:Seq><rdf:li>#{metadata_author()}</rdf:li></rdf:Seq></dc:creator>
    <xmp:CreatorTool>#{metadata_software()}</xmp:CreatorTool>
    <xmp:CreateDate>2026-01-02T03:04:05Z</xmp:CreateDate>
    </rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
    """

    {"<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R >>",
     [
       {6,
        "<< /Type /Metadata /Subtype /XML /Length #{byte_size(xmp)} >>\nstream\n#{xmp}\nendstream"},
       {7,
        "<< /Author (#{metadata_author()}) /Creator (#{metadata_software()}) " <>
          "/Producer (#{metadata_software()}) /Title (Interne Preisliste) " <>
          "/CreationDate (D:20260102030405Z) /ModDate (D:20260102030405Z) >>"}
     ]}
  end

  # 9 MB of filler in the catalog, so the object stream qpdf builds from it
  # inflates past `PdfGate`'s per-stream cut. The padding compresses to nothing,
  # which is what makes the finished file ~10 KB.
  defp catalog(:launch_padded) do
    {"<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /Launch /F (calc.exe) >> " <>
       "/Pad (" <> String.duplicate("A", 9_000_000) <> ") >>", []}
  end

  defp catalog(:embedded) do
    payload = "payload bytes"

    {"<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(f.txt) 6 0 R] >> >> >>",
     [
       {6, "<< /Type /Filespec /F (f.txt) /EF << /F 7 0 R >> >>"},
       {7, "<< /Length #{byte_size(payload)} >>\nstream\n#{payload}\nendstream"}
     ]}
  end

  # Serialises numbered objects with a cross-reference table. Nothing clever:
  # the offsets have to be right or poppler will not read the file, which is
  # what makes these fixtures worth having.
  defp build(objects, trailer_extra \\ "") do
    objects = Enum.sort_by(objects, &elem(&1, 0))

    {body, offsets} =
      Enum.reduce(objects, {"%PDF-1.7\n", %{}}, fn {number, content}, {acc, offsets} ->
        {acc <> "#{number} 0 obj\n#{content}\nendobj\n", Map.put(offsets, number, byte_size(acc))}
      end)

    size = (offsets |> Map.keys() |> Enum.max()) + 1

    entries =
      Enum.map_join(1..(size - 1), fn number ->
        offsets
        |> Map.fetch!(number)
        |> Integer.to_string()
        |> String.pad_leading(10, "0")
        |> Kernel.<>(" 00000 n \n")
      end)

    body <>
      "xref\n0 #{size}\n0000000000 65535 f \n" <>
      entries <>
      "trailer\n<< /Size #{size} /Root 1 0 R#{trailer_extra} >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
