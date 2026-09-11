defmodule Vutuv.Attachments.Format do
  @moduledoc """
  What kind of file this is (issue #2104) — read from the **bytes**, never
  from the extension and never from the content type the browser sent.

  Three families: `:pdf`, `:text` and a **picture** (`:jpeg`, `:png`, `:webp`,
  `:heic`), the last of which only a message carries (issue #2110). A PDF is
  identified by its header at offset 0; a picture by its own magic bytes; a
  text file by being text — valid UTF-8 from end to end with no control
  characters beyond tab, newline, carriage return and form feed. Every binary
  container fails that within a few bytes, which is why the text sniff needs no
  list of magic numbers to say no to.

  The extension still has a job: it decides which names this installation
  offers at all, and — once the bytes have said `:text` — whether the file is
  labelled Markdown or plain text, which nothing in the bytes can tell. The two
  have to **agree**: a ZIP called `invoice.pdf` and a PDF called `notes.txt`
  are both refused, so a lying name can never route a file past its own gate.

  For a picture the agreement is at the level of the **family**, not the exact
  format: a PNG that somebody's phone named `.jpg` is still a picture, and the
  bytes decide what it is stored and served as. A ZIP called `photo.png` is
  refused like any other lying name.
  """

  alias Vutuv.PostImageStore
  alias Vutuv.Uploads.PdfGate

  @pdf_magic "%PDF-"
  @pdf_extensions ~w(.pdf)
  @text_extensions ~w(.txt .md .markdown)
  @markdown_extensions ~w(.md .markdown)

  # The picture formats, as the bytes name them. `Vutuv.PostImageStore` owns
  # which *extensions* this installation offers (HEIC drops out of that list on
  # a libvips with no HEVC decoder), so there is one whitelist rather than two
  # that can disagree about what a photo is.
  @picture_kinds ~w(jpeg png webp heic)a

  # Everything outside these is a control character a text file has no reason
  # to carry, and every binary container has several in its first bytes.
  @control_regex ~r/[\x00-\x08\x0b\x0e-\x1f\x7f]/

  @doc """
  The extensions a picker offers. `.pdf` drops out on an installation without
  poppler, the way `.pdf` already drops out of the qualification whitelist
  without `pdftoppm`.

  `pictures?: true` adds the photo formats (issue #2110). The distinction is
  documents against documents-and-pictures, **not** posts against messages, so
  a third surface that takes photographs asks this same question rather than
  growing a whitelist named after itself. The picture half is
  `Vutuv.PostImageStore`'s own list, so an installation offers exactly the
  formats its libvips can decode (HEIC drops out without an HEVC decoder).
  """
  def extension_whitelist(opts \\ []) do
    documents =
      if PdfGate.available?(), do: @pdf_extensions ++ @text_extensions, else: @text_extensions

    if Keyword.get(opts, :pictures?, false) do
      documents ++ PostImageStore.extension_whitelist()
    else
      documents
    end
  end

  @doc "The kind `file_name`'s extension claims (`:pdf`, `:text`, `:picture`) or `nil`."
  def claimed_kind(file_name) do
    ext = extension(file_name)

    cond do
      ext in @pdf_extensions -> :pdf
      ext in @text_extensions -> :text
      ext in PostImageStore.extension_whitelist() -> :picture
      true -> nil
    end
  end

  @doc """
  The kind the bytes at `path` actually are (`:pdf`, `:text`, or one of the
  picture kinds) or `nil`.

  The PDF and picture answers cost a dozen bytes; only the text question needs
  the whole file, and only because being text is a claim about every byte in
  it. A PDF therefore reaches `Vutuv.Uploads.PdfGate` without this having read
  it once already.
  """
  def sniff(path) do
    head = header(path)

    cond do
      String.starts_with?(head, @pdf_magic) ->
        :pdf

      kind = picture_kind(head) ->
        kind

      text?(File.read!(path)) ->
        :text

      true ->
        nil
    end
  end

  @doc """
  The family a sniffed kind belongs to — what the claimed extension is compared
  against, so `.jpg` and `.png` are one answer while a ZIP under either name is
  still refused.
  """
  def family(kind) when kind in @picture_kinds, do: :picture
  def family(kind), do: kind

  # 16 bytes is enough for every magic here: a HEIC's brand sits at offset 8
  # and a WebP's at offset 8 as well, the PDF's and the rest at 0. An empty
  # file reads `:eof` rather than a binary, which every match below would
  # otherwise have to guard against.
  defp header(path) do
    case File.open!(path, [:read, :binary], &IO.binread(&1, 16)) do
      data when is_binary(data) -> data
      _eof -> ""
    end
  end

  defp picture_kind(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: :jpeg
  defp picture_kind(<<0x89, "PNG\r\n", 0x1A, 0x0A, _rest::binary>>), do: :png
  defp picture_kind(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: :webp

  # An ISO base-media file (HEIC/HEIF) names its brand in the `ftyp` box right
  # after the four-byte box size. The brands are the ones libvips' heifload
  # opens; anything else in that container is not a picture we would show.
  defp picture_kind(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>)
       when brand in ~w(heic heix heim heis hevc mif1 msf1 avif),
       do: :heic

  defp picture_kind(_head), do: nil

  @doc """
  The content type stored on the row. The kind comes from the bytes; for text
  the extension picks the flavour, because `# Title` and `# Title` are the
  same bytes whether the member called the file Markdown or not.
  """
  def content_type(:pdf, _file_name), do: "application/pdf"

  def content_type(kind, _file_name) when kind in @picture_kinds,
    do: "image/" <> Atom.to_string(kind)

  def content_type(:text, file_name) do
    if extension(file_name) in @markdown_extensions, do: "text/markdown", else: "text/plain"
  end

  @doc """
  The extension the stored copies get. For a PDF or a picture it is the
  **sniffed** kind's, so a `.pdf` name that was not one never reaches the disk
  under it and a PNG named `.jpg` is stored as what it is; for text the claimed
  extension is already known to be one of ours, and it is the only thing that
  tells `.md` from `.txt`.
  """
  def stored_extension(:pdf, _file_name), do: ".pdf"
  # `.jpg`, not `.jpeg`: the name every camera and every browser writes.
  def stored_extension(:jpeg, _file_name), do: ".jpg"

  def stored_extension(kind, _file_name) when kind in @picture_kinds,
    do: "." <> Atom.to_string(kind)

  def stored_extension(:text, file_name), do: extension(file_name)

  @doc "The downcased extension of `file_name`, `\"\"` when it has none."
  def extension(file_name), do: file_name |> Path.extname() |> String.downcase()

  @doc """
  Whether a stored row's `content_type` is a PDF — what a caller that has the
  row rather than the upload asks (`Vutuv.Attachments.apply_metadata_choice/1`).

  Deliberately **not** the full inverse of `content_type/2`, which also emits
  the picture types: the one consumer asks only "is there metadata in here for
  qpdf to remove", so everything that is not a PDF answers `:text` and is left
  alone. Widen it when a second caller needs `:picture` told apart, rather than
  leaving a promise the code does not keep.
  """
  def kind_of_content_type("application/pdf"), do: :pdf
  def kind_of_content_type(_not_a_pdf), do: :text

  defp text?(bytes), do: String.valid?(bytes) and not Regex.match?(@control_regex, bytes)
end
