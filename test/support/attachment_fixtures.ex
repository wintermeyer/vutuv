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

  @doc """
  A CV whose visible words are PDF token names: the page lists
  "HTML/CSS/JavaScript", a link annotation points at MDN's
  `/docs/Web/JavaScript` and the document title says it again. Nothing in it is
  an action — `pdfinfo` answers `JavaScript: no` and `pdfdetach` counts none —
  so it is the file issue #2136 is about. `compress: false` leaves the page's
  content stream uncompressed, which puts those words in the file's own bytes
  rather than behind zlib.
  """
  def web_skills_cv_pdf(dir, opts \\ []) do
    compress? = Keyword.get(opts, :compress, true)

    text =
      "BT /F1 12 Tf 72 700 Td (Jane Doe, frontend developer) Tj " <>
        "0 -16 Td (Skills: HTML/CSS/JavaScript, TypeScript/JavaScript, Elixir) Tj " <>
        "0 -16 Td (Wrote the team notes on /OpenAction, /Launch and /EmbeddedFile) Tj ET"

    contents =
      if compress?,
        do: stream_object(:zlib.compress(text), " /Filter /FlateDecode"),
        else: stream_object(text)

    write(
      dir,
      if(compress?, do: "cv.pdf", else: "cv-uncompressed.pdf"),
      pdf(:web_skills_cv, [{4, contents}], "/Info 7 0 R ")
    )
  end

  @doc """
  A PDF whose JavaScript hangs somewhere other than the catalog's name tree:
  `:open_action`, `:catalog_aa`, `:page_aa`, `:annotation`, `:next_dict`,
  `:next_array` or `:field_calculate`. The last three, and every one of the
  multi-page shapes below, are constructs `pdfinfo` does **not** report
  (measured 2026-09-11), which is why `/JavaScript` is in the byte scan beside
  it rather than instead of it.
  """
  def action_javascript_pdf(dir, where)
      when where in [
             :open_action,
             :catalog_aa,
             :page_aa,
             :annotation,
             :next_dict,
             :next_array,
             :field_calculate
           ],
      do: write(dir, "js-#{where}.pdf", pdf(:"js_#{where}"))

  @doc """
  A `pages`-page PDF whose page `on` opens with a JavaScript action. Bare
  `pdfinfo` reads **page 1 only**, so it answers `JavaScript: no` for every one
  of these while answering `yes` for the identical script on page 1 — which is
  why the gate passes it a page range, and why a one-page fixture calibrates
  nothing (issue #2136).
  """
  def page_javascript_pdf(dir, pages, on) do
    write(dir, "js-page-#{on}-of-#{pages}.pdf", multi_page(pages, on))
  end

  @doc """
  A PDF whose last byte is a lone `<`, with a name in the raw bytes so the
  blanking pass runs at all. A pass that resumed at `at + reach` rather than
  past the `<` had nothing to reach into and looped for ever on this.
  """
  def dangling_bracket_pdf(dir),
    do: write(dir, "dangling.pdf", pdf(:plain, [{6, "<< /Note (/Launch) >>"}]) <> "\n<")

  @doc """
  A PDF carrying another file on a `/FileAttachment` annotation rather than in
  the `/EmbeddedFiles` name tree — with `typed: false`, without the
  `/Type /Filespec` and `/Type /EmbeddedFile` that would name it as one. Both
  rest on `pdfdetach -list` alone since #2136.
  """
  def file_attachment_pdf(dir, opts \\ []) do
    kind =
      if Keyword.get(opts, :typed, true), do: :file_attachment, else: :file_attachment_untyped

    write(dir, "#{kind}.pdf", pdf(kind))
  end

  @doc """
  A PDF carrying another file as a PDF 2.0 **associated file**, hung off the
  catalog's `/AF`. `pdfdetach -list` answers `0 embedded files` for this one
  (measured 2026-09-11), so it is the byte scan's `/EmbeddedFile` that catches
  it — which is why that name stayed in the scan when `/JavaScript` left it.
  """
  def associated_file_pdf(dir), do: write(dir, "associated.pdf", pdf(:associated_file))

  @doc """
  A PDF whose `/OpenAction` and `/Launch` are spelled with `#XX` escapes —
  `/Open#41ction << /S /L#61unch >>` — which is the same name to a reader.
  """
  def hex_escaped_launch_pdf(dir), do: write(dir, "hex-escaped.pdf", pdf(:hex_escaped))

  @doc """
  A clean PDF with a second revision appended: a new catalog carrying a launch
  action, a second cross-reference section pointing at it and a `/Prev` back to
  the first. The bytes of the clean revision are untouched.
  """
  def incremental_launch_pdf(dir) do
    base = pdf(:plain)
    [_all, previous] = Regex.run(~r/startxref\s+(\d+)/, base)

    added =
      "6 0 obj\n<< /Type /Catalog /Pages 2 0 R " <>
        "/OpenAction << /S /Launch /F (calc.exe) >> >>\nendobj\n"

    at = byte_size(base)

    write(
      dir,
      "incremental.pdf",
      base <>
        added <>
        "xref\n0 1\n0000000000 65535 f \n6 1\n" <>
        String.pad_leading(Integer.to_string(at), 10, "0") <>
        " 00000 n \ntrailer\n<< /Size 7 /Root 6 0 R /Prev #{previous} >>\n" <>
        "startxref\n#{at + byte_size(added)}\n%%EOF\n"
    )
  end

  @doc """
  A launch action inside a Flate stream whose inflated bytes open a string
  before it and close one after it. A blanking pass that took those brackets at
  face value would blank the dictionary between them and never see the action;
  one that refuses to exempt a range holding a `<<` reads it (issue #2136).
  """
  def string_wrapped_launch_pdf(dir) do
    flate_pdf(dir, "string-wrapped.pdf", [
      "(a decoy string that opens here\n",
      "<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /Launch /F (calc.exe) >> >>\n",
      ") and closes here\n"
    ])
  end

  @doc "A stream of a few hundred bytes that inflates to 20 MB."
  def decompression_bomb_pdf(dir),
    do: flate_pdf(dir, "bomb.pdf", :binary.copy("A", 20_000_000))

  @doc """
  `bytes` of `%` with a `<<` behind them and no newline anywhere: one comment
  that runs to the end of the buffer, holding a dictionary, so the blanking
  pass may not exempt it. A pass that started over one byte later after
  refusing it re-read the whole run each time, and a file only has to name
  `/Launch` once — in a string, harmlessly — for that pass to run at all.
  """
  def comment_flood_pdf(dir, bytes \\ 30_000) do
    flate_pdf(dir, "comment-flood-#{bytes}.pdf", [
      "(a link to /Launch, which is only a word)",
      :binary.copy("%", bytes),
      "<< /Type /Catalog >>"
    ])
  end

  @doc "A PDF header with nothing readable behind it."
  def header_then_garbage_pdf(dir),
    do: write(dir, "broken.pdf", "%PDF-1.7\n" <> :binary.copy(<<0xFF>>, 512))

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

    write(
      dir,
      "endstream-decoy.pdf",
      pdf(:plain, [{6, stream_object(body, " /Filter /FlateDecode")}])
    )
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

  @doc "A plain text file."
  def text_file(dir, body \\ "Just some notes.\nOn two lines.\n"),
    do: write(dir, "notes.txt", body)

  @doc "A Markdown file."
  def markdown_file(dir), do: write(dir, "readme.md", "# Title\n\nA paragraph.\n")

  @doc "A file of `bytes` zero bytes under a `.txt` name."
  def sized_file(dir, bytes, name \\ "big.txt"),
    do: write(dir, name, :binary.copy("a", bytes))

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

  # A one-page PDF whose object 6 is `payload`, Flate-compressed.
  defp flate_pdf(dir, name, payload) do
    stream = payload |> IO.iodata_to_binary() |> :zlib.compress()

    write(dir, name, pdf(:plain, [{6, stream_object(stream, " /Filter /FlateDecode")}]))
  end

  defp stream_object(payload, extra \\ ""),
    do: "<< /Length #{byte_size(payload)}#{extra} >>\nstream\n#{payload}\nendstream"

  ## The PDFs themselves

  @content "BT /F1 24 Tf 72 700 Td (hello) Tj ET"
  @js_action "<< /S /JavaScript /JS (app.alert\\(1\\);) >>"

  defp pdf(kind, more \\ [], trailer_extra \\ "") do
    {root, extra} = catalog(kind)

    objects =
      [
        {1, root},
        {2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"},
        {3, page(kind)},
        {4, stream_object(@content)},
        {5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
        | extra
      ] ++ more

    # Later entries win, so a fixture can hand `pdf/3` its own object 4.
    objects |> Map.new() |> Map.to_list() |> build(trailer_extra)
  end

  # The page dictionary, with whatever this kind hangs off it in the middle:
  # `:page_action` an additional action, which is where a launch goes when there
  # is no `/OpenAction` to put it in, and the annotation kinds an `/Annots`.
  defp page(kind) do
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " <>
      page_extra(kind) <> "/Resources << /Font << /F1 5 0 R >> >> >>"
  end

  defp page_extra(:page_action), do: "/AA << /O << /S /Launch /F (calc.exe) >> >> "
  defp page_extra(:js_page_aa), do: "/AA << /O #{@js_action} >> "

  defp page_extra(kind)
       when kind in [
              :js_annotation,
              :js_field_calculate,
              :file_attachment,
              :file_attachment_untyped,
              :web_skills_cv
            ],
       do: "/Annots [6 0 R] "

  defp page_extra(_kind), do: ""

  # A document of `count` pages, each with its own content stream saying which
  # page it is, so a rendered preview can be told from its neighbours. Object
  # numbers: 1 catalog, 2 the page tree, 3 the shared font, then a page and a
  # content object per page.
  defp multi_page(count, script_on \\ nil) do
    pages = for index <- 0..(count - 1), do: {4 + index * 2, 5 + index * 2}
    kids = Enum.map_join(pages, " ", fn {page, _content} -> "#{page} 0 R" end)

    page_objects =
      Enum.flat_map(Enum.with_index(pages, 1), fn {{page, content}, number} ->
        text = "BT /F1 96 Tf 72 400 Td (#{number}) Tj ET"
        opens = if number == script_on, do: "/AA << /O #{@js_action} >> ", else: ""

        [
          {page,
           "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents #{content} 0 R " <>
             opens <> "/Resources << /Font << /F1 3 0 R >> >> >>"},
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
     [{6, @js_action}]}
  end

  # Every word in this one is inside a PDF string, which is what the gate blanks
  # before it looks for a name: the page text, the `/URI` it links to and the
  # `/Title` the trailer points at (issue #2136).
  defp catalog(:web_skills_cv) do
    {"<< /Type /Catalog /Pages 2 0 R >>",
     [
       {6,
        "<< /Type /Annot /Subtype /Link /Rect [72 690 300 710] " <>
          "/A << /S /URI /URI (https://developer.mozilla.org/en-US/docs/Web/JavaScript) >> >>"},
       {7, "<< /Title (Curriculum Vitae - HTML/CSS/JavaScript) >>"}
     ]}
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

  defp catalog(:js_open_action),
    do: {"<< /Type /Catalog /Pages 2 0 R /OpenAction #{@js_action} >>", []}

  defp catalog(:js_catalog_aa),
    do: {"<< /Type /Catalog /Pages 2 0 R /AA << /WC #{@js_action} >> >>", []}

  defp catalog(:js_page_aa), do: {"<< /Type /Catalog /Pages 2 0 R >>", []}

  defp catalog(:js_annotation) do
    {"<< /Type /Catalog /Pages 2 0 R >>",
     [{6, "<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] /A #{@js_action} >>"}]}
  end

  # A destination that satisfies `destination?/1`, with the script chained
  # behind it. `pdfinfo` answers `JavaScript: no` for both of these, page range
  # or not (measured 2026-09-11).
  defp catalog(:js_next_dict) do
    {"<< /Type /Catalog /Pages 2 0 R " <>
       "/OpenAction << /S /GoTo /D [3 0 R /Fit] /Next #{@js_action} >> >>", []}
  end

  defp catalog(:js_next_array) do
    {"<< /Type /Catalog /Pages 2 0 R " <>
       "/OpenAction << /S /GoTo /D [3 0 R /Fit] /Next [#{@js_action}] >> >>", []}
  end

  # A form field that recalculates itself with a script.
  defp catalog(:js_field_calculate) do
    {"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] >> >>",
     [
       {6,
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (total) /Rect [0 0 10 10] " <>
          "/AA << /C #{@js_action} >> >>"}
     ]}
  end

  defp catalog(:associated_file) do
    {"<< /Type /Catalog /Pages 2 0 R /AF [6 0 R] >>",
     [
       {6, "<< /Type /Filespec /F (secret.txt) /EF << /F 7 0 R >> >>"},
       {7, "<< /Type /EmbeddedFile /Length 6 >>\nstream\nhidden\nendstream"}
     ]}
  end

  defp catalog(:hex_escaped) do
    {"<< /Type /Catalog /Pages 2 0 R " <>
       "/Open#41ction << /S /L#61unch /F (calc.exe) >> >>", []}
  end

  defp catalog(:file_attachment) do
    {"<< /Type /Catalog /Pages 2 0 R >>",
     [
       {6,
        "<< /Type /Annot /Subtype /FileAttachment /Rect [0 0 10 10] " <>
          "/FS << /Type /Filespec /F (secret.txt) /EF << /F 7 0 R >> >> >>"},
       {7, "<< /Type /EmbeddedFile /Length 6 >>\nstream\nhidden\nendstream"}
     ]}
  end

  # The same attachment with nothing naming it as one: no `/Type /Filespec`, no
  # `/Type /EmbeddedFile`. `pdfdetach` still counts it (measured 2026-09-11).
  defp catalog(:file_attachment_untyped) do
    {"<< /Type /Catalog /Pages 2 0 R >>",
     [
       {6,
        "<< /Type /Annot /Subtype /FileAttachment /Rect [0 0 10 10] " <>
          "/FS << /F (secret.txt) /EF << /F 7 0 R >> >> >>"},
       {7, "<< /Length 6 >>\nstream\nhidden\nendstream"}
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
      "trailer\n<< /Size #{size} #{trailer_extra}/Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
