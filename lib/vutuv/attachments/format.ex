defmodule Vutuv.Attachments.Format do
  @moduledoc """
  What kind of file this is (issue #2104) — read from the **bytes**, never
  from the extension and never from the content type the browser sent.

  Two answers today: `:pdf` and `:text`. A PDF is identified by its header at
  offset 0; a text file by being text — valid UTF-8 from end to end with no
  control characters beyond tab, newline, carriage return and form feed. Every
  binary container fails that within a few bytes, which is why the sniff needs
  no list of magic numbers to say no to.

  The extension still has a job: it decides which names this installation
  offers at all, and — once the bytes have said `:text` — whether the file is
  labelled Markdown or plain text, which nothing in the bytes can tell. The two
  have to **agree**: a ZIP called `invoice.pdf` and a PDF called `notes.txt`
  are both refused, so a lying name can never route a file past its own gate.
  """

  alias Vutuv.Uploads.PdfGate

  @pdf_magic "%PDF-"
  @pdf_extensions ~w(.pdf)
  @text_extensions ~w(.txt .md .markdown)
  @markdown_extensions ~w(.md .markdown)

  # Everything outside these is a control character a text file has no reason
  # to carry, and every binary container has several in its first bytes.
  @control_regex ~r/[\x00-\x08\x0b\x0e-\x1f\x7f]/

  @doc """
  The extensions the composer offers. `.pdf` drops out on an installation
  without poppler, the way `.pdf` already drops out of the qualification
  whitelist without `pdftoppm`.
  """
  def extension_whitelist do
    if PdfGate.available?(), do: @pdf_extensions ++ @text_extensions, else: @text_extensions
  end

  @doc "The kind `file_name`'s extension claims (`:pdf`, `:text`) or `nil`."
  def claimed_kind(file_name) do
    case extension(file_name) do
      ext when ext in @pdf_extensions -> :pdf
      ext when ext in @text_extensions -> :text
      _unknown -> nil
    end
  end

  @doc """
  The kind the bytes at `path` actually are (`:pdf`, `:text`) or `nil`.

  The PDF answer costs five bytes; only the text question needs the whole
  file, and only because being text is a claim about every byte in it. A PDF
  therefore reaches `Vutuv.Uploads.PdfGate` without this having read it once
  already.
  """
  def sniff(path) do
    if header(path) == @pdf_magic do
      :pdf
    else
      if text?(File.read!(path)), do: :text
    end
  end

  defp header(path) do
    File.open!(path, [:read, :binary], &IO.binread(&1, byte_size(@pdf_magic)))
  end

  @doc """
  The content type stored on the row. The kind comes from the bytes; for text
  the extension picks the flavour, because `# Title` and `# Title` are the
  same bytes whether the member called the file Markdown or not.
  """
  def content_type(:pdf, _file_name), do: "application/pdf"

  def content_type(:text, file_name) do
    if extension(file_name) in @markdown_extensions, do: "text/markdown", else: "text/plain"
  end

  @doc """
  The extension the stored copies get. For a PDF it is the sniffed kind's, so
  a `.pdf` name that was not one never reaches the disk under it; for text the
  claimed extension is already known to be one of ours, and it is the only
  thing that tells `.md` from `.txt`.
  """
  def stored_extension(:pdf, _file_name), do: ".pdf"
  def stored_extension(:text, file_name), do: extension(file_name)

  @doc "The downcased extension of `file_name`, `\"\"` when it has none."
  def extension(file_name), do: file_name |> Path.extname() |> String.downcase()

  defp text?(bytes), do: String.valid?(bytes) and not Regex.match?(@control_regex, bytes)
end
