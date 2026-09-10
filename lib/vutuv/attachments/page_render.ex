defmodule Vutuv.Attachments.PageRender do
  @moduledoc """
  Turns one page of an uploaded file into one raster (issue #2105). Two
  backends, one per format, and both of them answer `nil` from `renderer/1`
  on a host that cannot run them at all — which is what lets
  `Vutuv.Attachments.Pages` settle such a file instead of queueing it for ever.

  ## A PDF page: poppler, not libvips

  The issue this was built from says libvips renders a PDF through its Poppler
  loader. **It does not, here, and this was measured** (2026-09-10): `vix`
  builds its `Vix.Vips.Operation` functions from the operation table of the
  libvips it is linked against, and the precompiled libvips it ships
  (8.17.1, the default `VIX_COMPILATION_MODE=PRECOMPILED_NIF_AND_LIBVIPS`)
  has no PDF loader at all — `Vix.Vips.Operation.pdfload/1` is *undefined*,
  not merely failing, and `otool -L` on the bundled `libvips.42.dylib` shows
  no poppler linked. The Homebrew `vips` CLI on the same machine does list
  `pdfload`, which is what makes the claim look true from outside. It is the
  same gap the post-image store already records for HEIC.

  So a page is rendered by **`pdftoppm`**, which this project already shells
  out to in three places (`Vutuv.QualificationDocument`,
  `Vutuv.JobReferenceDocument`, `Vutuv.References.TextExtraction`), which ships
  in the same `poppler-utils` package as the `pdfinfo` the upload gate already
  needs, and which CI already installs. Nothing new has to be on any box.

  ## A text or Markdown page: the Chromium the screenshot pipeline runs

  `Vutuv.PageScreenshot.capture/3` — the raw entry point
  `Vutuv.Moderation.EvidenceScreenshot` already uses, deliberately neither
  gated on `:generate_screenshots` (that flag is about fetching *other
  people's* pages, and an air-gapped installation still wants to see its own
  files) nor routed through the SSRF proxy (there is no host to vet in a
  `file://` URL).

  **The page is rendered offline**, because its content is a member's file: a
  Markdown image or a stylesheet reference would otherwise make this server
  fetch an address the member chose — a beacon at best. The document carries
  `Content-Security-Policy: default-src 'none'`, which Chromium enforces on
  every **subresource**, and the browser is launched with `offline: true`,
  which fails every name resolution.

  Both of those stop a *subresource*, and neither covers **top-level
  navigation**: CSP has no directive for it here and a `file://` URL asks no
  resolver anything, so a document carrying
  `<meta http-equiv="refresh" content="0;url=file:///etc/passwd">` would
  navigate and be photographed. What actually keeps that out of a member's file
  is one layer up — `VutuvWeb.Markdown.render/1` escapes every `<` before
  Earmark sees it, then sanitizes, then strips `<img>` — so nothing a member
  writes can become a tag at all. Which is why loosening that Markdown pipeline
  (raw HTML pass-through, a different renderer) is a change to *this* module's
  threat model as much as to the post body's, and would need a navigation
  answer of its own before it shipped.
  """

  alias Vutuv.Attachments.Attachment
  alias Vutuv.AttachmentStore
  alias Vutuv.PageScreenshot

  require Logger

  # A4 at 150 dpi, and the resolution `pdftoppm` renders at: a letter page
  # comes out 1275x1650, so the 1600px `large` version is a downscale rather
  # than an upscale, and body text stays legible in it.
  @dpi "150"
  @window {1240, 1754}

  # How much of a text file reaches the document. Only the first screenful is
  # captured, so anything past this could not be seen — and a 20 MB text file
  # would otherwise be parsed into a DOM to photograph the top of. Cut by
  # graphemes, never by bytes, so the cut cannot land inside a codepoint.
  @text_limit 20_000

  @doc """
  The binary that would render this file's pages, or `nil` when this host has
  none — a PDF needs `pdftoppm`, anything else needs Chromium.

  Deliberately **not** cached in `:persistent_term` like the four other
  capability probes in this tree: this runs once per uploaded file rather than
  once per request, `System.find_executable/1` is a `$PATH` walk, and a cached
  probe is a fifth thing a test has to remember to forget.
  """
  def renderer(%Attachment{content_type: "application/pdf"}), do: executable(pdftoppm())
  def renderer(%Attachment{}), do: executable(PageScreenshot.binary())

  # `PageScreenshot.binary/0` hands back a configured path unchecked, so ask
  # the filesystem: a `CHROMIUM_PATH` pointing at nothing must read as "no
  # browser here", not as a browser that fails on every file.
  defp executable(nil), do: nil

  defp executable(name) do
    cond do
      System.find_executable(name) -> name
      File.exists?(name) -> name
      true -> nil
    end
  end

  defp pdftoppm, do: Keyword.get(config(), :pdftoppm, "pdftoppm")
  defp config, do: Application.fetch_env!(:vutuv, :attachments)

  @doc """
  Renders page `position` (counted from zero) of `attachment` into `dest`, a
  path ending in `.png`. `:ok`, or `{:error, reason}` — and the reason is what
  the pipeline decides a strike on, so it names the renderer that failed.
  """
  def render(%Attachment{content_type: "application/pdf"} = attachment, position, dest) do
    case AttachmentStore.served_path(attachment.token) do
      nil -> {:error, :file_gone}
      source -> render_pdf(source, position, dest)
    end
  end

  def render(%Attachment{} = attachment, _position, dest) do
    case AttachmentStore.served_path(attachment.token) do
      nil -> {:error, :file_gone}
      source -> render_text(attachment, source, dest)
    end
  end

  # One poppler run per page, deliberately, although `-f 1 -l 3` would parse the
  # document once instead of three times: a resumed render (the whole point of
  # the pipeline's claim) has to be able to make *page 4 alone*, and a failure
  # has to name the page it happened on. Three parses of a 20 MB PDF is the
  # price, and it is paid in a background task at concurrency 1.
  #
  # `-singlefile` writes exactly `<base>.png` rather than a zero-padded name
  # that depends on the document's page count, so there is no wildcard to guess
  # and nothing left behind when the run fails.
  defp render_pdf(source, position, dest) do
    page = Integer.to_string(position + 1)
    base = Path.rootname(dest)

    case System.cmd(
           pdftoppm(),
           ["-f", page, "-l", page, "-r", @dpi, "-png", "-singlefile", source, base],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        if File.exists?(dest), do: :ok, else: {:error, :no_page}

      {out, status} ->
        Logger.info("pdftoppm failed (#{status}): #{String.slice(out, 0, 200)}")
        {:error, {:pdftoppm, status}}
    end
  rescue
    # An unusable `PDFTOPPM_PATH` (a directory, a file with no exec bit) raises
    # rather than answering non-zero, and a render must never take the pipeline
    # process down with it.
    exception -> {:error, {:pdftoppm, Exception.message(exception)}}
  end

  defp render_text(attachment, source, dest) do
    html = Path.rootname(dest) <> ".html"
    File.write!(html, document(attachment, head_of(source)))

    try do
      PageScreenshot.capture("file://" <> html, dest, window: @window, offline: true)
    after
      File.rm(html)
    end
  end

  # Only as much of the file as could possibly be seen. A text file may be 20 MB
  # and every byte past the cut would be parsed into a DOM to photograph the top
  # of it. Four bytes per grapheme is UTF-8's widest, so this is always enough
  # to fill `@text_limit`; the cut can land inside a codepoint, and
  # `String.replace_invalid/2` drops the half that is left.
  defp head_of(path) do
    {:ok, file} = File.open(path, [:read, :binary])

    try do
      case IO.binread(file, @text_limit * 4) do
        :eof -> ""
        data -> String.replace_invalid(data, "")
      end
    after
      File.close(file)
    end
  end

  @doc """
  The page a text or Markdown file is drawn as. Public so the document itself
  can be asserted on without a browser — the capture is the one step a test
  cannot run where Chromium is absent, which includes CI.
  """
  # `VutuvWeb.Markdown.render/1` is a web module called from a context, which
  # this project otherwise reserves for `VutuvWeb.Gettext` and `Endpoint.url/0`.
  # The alternative is a second Markdown-to-HTML path in `Vutuv.*`, and two
  # renderers that could disagree about what a member's Markdown means is a far
  # worse trade than one import: what a reader sees under the post has to be
  # what the preview shows.
  def document(%Attachment{content_type: "text/markdown"} = attachment, body) do
    body
    |> String.slice(0, @text_limit)
    |> VutuvWeb.Markdown.render()
    |> Phoenix.HTML.safe_to_string()
    |> page(attachment.file_name)
  end

  def document(%Attachment{} = attachment, body) do
    escaped = body |> String.slice(0, @text_limit) |> Plug.HTML.html_escape()

    page("<pre>#{escaped}</pre>", attachment.file_name)
  end

  defp page(inner, file_name) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <title>#{Plug.HTML.html_escape(file_name)}</title>
    <style>
      html { background: #fff; }
      body {
        margin: 0;
        padding: 64px 72px;
        color: #111827;
        background: #fff;
        font: 17px/1.6 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
        word-wrap: break-word;
      }
      h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 0.5em; }
      h1 { font-size: 2em; margin-top: 0; }
      p, li, blockquote { margin: 0 0 0.9em; }
      pre { white-space: pre-wrap; font: 15px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      blockquote { border-left: 3px solid #d1d5db; padding-left: 1em; color: #4b5563; }
      table { border-collapse: collapse; }
      td, th { border: 1px solid #d1d5db; padding: 4px 8px; }
      a { color: #1d4ed8; }
      img { display: none; }
    </style>
    </head>
    <body>#{inner}</body>
    </html>
    """
  end
end
