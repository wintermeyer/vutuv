defmodule Vutuv.Posts.LinkedFile do
  @moduledoc """
  The preview picture for a post whose one link answers with a **file** rather
  than a page. Until this existed such a link was refused outright
  (`{:not_a_page, type}`, see `Vutuv.PageScreenshot.page_response/1`), because
  Chromium saves what it cannot render as a download, and the card showed the
  bare link.

  A file is not photographed, it is read. What the card shows depends on what
  the file is:

    * a **picture** is its own preview;
    * a **PDF** previews with its first page, drawn by `pdftoppm`;
    * a **text or Markdown** file is drawn as one page, offline, by the same
      renderer an uploaded text file uses;
    * anything else (an archive, an office document, a clip) keeps the plain
      link, and nothing is downloaded at all.

  A PDF and a text file go through the renderer a member's own upload uses
  (`Vutuv.Attachments.PageRender.render_file/4`), so a linked file and an
  attached one look the same; a picture is decoded within the pixel budget of
  `Vutuv.Uploads.Spec`. The result is stored
  frameless like a YouTube thumbnail, since there is no browser window to draw
  around a file, and it goes through the AI image scan like every capture.

  **The download is bounded before it starts.** At most the attachment size
  limit (`ATTACHMENT_MAX_MB`), dropped during receipt rather than after it
  (`Vutuv.Http.capped_collector/1`), and a picture or PDF that does not fit is
  refused rather than cut. Nothing of a file outlives the render: it goes to a
  temporary directory and is removed there.

  **What it trusts, and what it does not.** The host has been vetted by the
  probe before this runs (`Vutuv.Posts.Screenshots.ensure_http_ok/1`: SSRF
  guard, same-site redirects only), and the download fetches that exact address
  without following anything. The type the server names only picks the
  renderer; the bytes must agree (a PDF starts with `%PDF-`, a picture must
  decode within the pixel budget of `Vutuv.Uploads.Spec`). `Vutuv.Uploads.PdfGate`
  is **not** asked: it decides whether a file may be *handed out* (scripts,
  embedded files, actions on open), and this file is never handed out, only
  rendered, and the gate's own `pdfinfo` parses the same untrusted bytes
  `pdftoppm` does.

  `LINK_FILE_PREVIEWS=false` (`:link_file_previews`) restores the old refusal
  without touching page captures; `:generate_screenshots` off switches both off.
  """

  alias Vutuv.Attachments
  alias Vutuv.Attachments.Format
  alias Vutuv.Attachments.PageRender
  alias Vutuv.Posts.Screenshots
  alias Vutuv.SocialFeed.Http
  alias Vutuv.Uploads.Spec

  @image_types ~w(image/png image/jpeg image/webp image/gif image/avif)
  @pdf "application/pdf"
  # What a server calls Markdown varies; the renderer knows one name for it.
  @text_types %{
    "text/plain" => "text/plain",
    "text/markdown" => "text/markdown",
    "text/x-markdown" => "text/markdown"
  }

  # A text file only shows its first screenful, so it never needs the whole
  # allowance; a picture or a PDF cut short is no picture or PDF at all.
  @text_bytes 256 * 1024

  @doc "Whether the installation previews linked files at all."
  def enabled?, do: Application.get_env(:vutuv, :link_file_previews, true)

  @doc "Whether a file served as `type` gets a preview (and is downloaded)."
  def previewable?(type) when type in @image_types or type == @pdf, do: true
  def previewable?(type) when is_map_key(@text_types, type), do: true
  def previewable?(_type), do: false

  @doc """
  Downloads the file at `url` (served as `type`) and renders its preview into
  a PNG in `dir`. `{:ok, png_path}`, or `{:error, reason}`: `:probe_failed`
  when the server could not be reached or answered differently this time (the
  queue retries that), anything else is a property of the file.

  The renderer is asked before the download, so a host that cannot draw the
  file never fetches it.
  """
  def render(url, type, dir) do
    kind = Map.get(@text_types, type, type)
    source = Path.join(dir, "source")
    dest = Path.join(dir, "preview.png")

    with true <- PageRender.renderable_type?(kind) || {:error, :no_renderer},
         {:ok, body} <- fetch(url, type),
         :ok <- File.write(source, body),
         :ok <- draw(kind, source, dest, file_name(url)) do
      {:ok, dest}
    end
  end

  defp draw(type, source, dest, _name) when type in @image_types do
    case Spec.raster_png(source) do
      {:ok, png} -> File.write(dest, png)
      :error -> {:error, :not_an_image}
    end
  end

  defp draw(@pdf, source, dest, name) do
    if Format.sniff(source) == :pdf,
      do: PageRender.render_file(@pdf, name, source, dest),
      else: {:error, :not_a_pdf}
  end

  defp draw(type, source, dest, name), do: PageRender.render_file(type, name, source, dest)

  defp fetch(url, type) do
    max = if Map.has_key?(@text_types, type), do: @text_bytes, else: Attachments.max_filesize()

    url
    |> Http.base_options(max + 1, "*/*")
    |> Keyword.put(:receive_timeout, 15_000)
    |> Keyword.merge(Screenshots.req_options())
    |> Req.get()
    |> body(max, type)
  end

  defp body({:ok, %Req.Response{status: 200, body: body} = resp}, max, type)
       when is_binary(body) do
    cond do
      Vutuv.Http.media_type(resp) != type -> {:error, :probe_failed}
      byte_size(body) <= max -> {:ok, body}
      Map.has_key?(@text_types, type) -> {:ok, binary_part(body, 0, max)}
      true -> {:error, :too_large}
    end
  end

  defp body(_answer, _max, _type), do: {:error, :probe_failed}

  # What the text renderer titles its page with: the last path segment, which
  # is what a reader would call the file.
  defp file_name(url) do
    case URI.parse(url).path do
      path when is_binary(path) and path not in ["", "/"] -> decode(Path.basename(path))
      _none -> "file"
    end
  end

  # A stray `%` in somebody else's address raises in `URI.decode/1`; the name
  # is a title, so the raw segment is good enough.
  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end
end
