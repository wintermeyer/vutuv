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

  @doc "A PDF encrypted with a user password — `pdfinfo` cannot even open it."
  def encrypted_pdf(dir) do
    encrypt(dir, "encrypted.pdf", ["--user-password=secret", "--owner-password=owner"])
  end

  @doc """
  A PDF with an owner password only: readable by anybody, but restricted, and
  the shape `pdfinfo` answers `Encrypted: yes` for rather than refusing.
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

  @doc "A ZIP file under a `.pdf` name: the extension lies, the bytes do not."
  def zip_named_pdf(dir) do
    # A real (empty) ZIP: the end-of-central-directory record on its own.
    write(dir, "invoice.pdf", "PK\x05\x06" <> :binary.copy(<<0>>, 18))
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
    source = plain_pdf(dir)
    dest = Path.join(dir, name)

    qpdf =
      System.find_executable("qpdf") ||
        raise "qpdf is not installed; the encrypted-PDF tests need it to build their fixture"

    {out, status} =
      System.cmd(qpdf, ["--encrypt"] ++ args ++ ["--bits=256", "--", source, dest],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("qpdf could not encrypt the fixture (#{status}): #{out}")
    dest
  end

  defp write(dir, name, bytes) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  ## The PDFs themselves

  @content "BT /F1 24 Tf 72 700 Td (hello) Tj ET"

  defp pdf(kind) do
    {root, extra} = catalog(kind)

    build([
      {1, root},
      {2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"},
      {3, page(kind)},
      {4, "<< /Length #{byte_size(@content)} >>\nstream\n#{@content}\nendstream"},
      {5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
      | extra
    ])
  end

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
  defp build(objects) do
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
      "trailer\n<< /Size #{size} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
