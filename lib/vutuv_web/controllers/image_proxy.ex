defmodule VutuvWeb.ImageProxy do
  @moduledoc """
  The shared serving half of the authorizing image proxies
  (`VutuvWeb.PostImageController`, `VutuvWeb.JobPostingImageController`,
  `VutuvWeb.OrganizationImageController`): the `"<version>.<ext>"` parser and
  the X-Accel-Redirect / send_file switch, written once so the serving
  topology and the 404-on-anything-unknown posture cannot drift between the
  three (the v7.15.5 X-Accel→send_file production fix had to be found in one
  place per proxy before this).

  The controllers keep what genuinely differs: the row lookup, the
  visibility policy, and any per-response decoration (the post proxy's
  download filename and its on-the-fly `og.jpg`).

  ## What a browser may remember (issue #2170)

  Every response here is an **authorization** decision, and authorization is
  revoked — a post is switched to restricted, a picture is frozen for
  copyright, a member is suspended. The header said
  `max-age=31536000, immutable`, which tells the browser not to ask again for a
  year, so every revocation reached only the machines that had not loaded the
  picture yet. `immutable` is a claim about the **bytes** (true here: the token
  is random per image and a re-crop rotates the URL, `PostImage.url/2`) and the
  browser cannot tell that from a claim about the reader.

  Two tiers now, and both tighten:

    * **A derived version** — a size of a picture, the thing a page renders —
      answers `private, max-age=300, must-revalidate` plus an `ETag`. Five
      minutes is one reading session, so a feed scroll still costs no request;
      past it the browser asks, and because the bytes are content-addressed the
      answer is a 304 rather than the file. A revocation therefore reaches a
      browser that already holds the picture within five minutes instead of
      within a year.
    * **A file hand-over** — the full-resolution original a post author or a
      Media Kit gives away — answers `private, no-store`. It is fetched by a
      deliberate click, never by a page render, so storing nothing costs a page
      nothing, and a takedown must not leave a print-quality copy behind.

  Rejected, with the reason: `no-store` on the derived versions (a feed full of
  pictures would re-download every one); `no-cache` on them (a conditional
  request per picture per page load, for a promise five minutes already keeps);
  a separate, sharper window for a **restricted** post (knowing whether a
  response is also public costs an extra query per request, and the takedown
  promise binds the public class just as hard — measured on this installation's
  dev copy, 0 of 887 posts carried a denial); and `Vary`, which keys on a
  **request header** — the allowed request and the revoked one carry the
  identical `Cookie`, so no `Vary` value can tell them apart.

  The conditional request is answered **inside** `serve/3`, which is only
  reached once the controller's own `with` chain has authorized the reader, so
  a 304 is as authorized as the 200 it stands in for and a revoked reader
  arriving with the matching `ETag` still gets the 404.
  """

  import Plug.Conn

  alias VutuvWeb.ControllerHelpers

  # Five minutes: one reading session, the same "fresh enough" unit the feed
  # and the agent documents already use for public HTML.
  @max_age 300
  @cache_control "private, max-age=#{@max_age}, must-revalidate"
  @no_store "private, no-store"

  @doc """
  Parses a `"<version>.<ext>"` path segment against the subject's `versions`
  whitelist. Only the served extensions resolve — `"original.*"` never does;
  the legacy `".webp"` stays accepted (old stored bodies and bookmarked URLs
  carry it, and the response is whatever file is on disk). Returns the
  version string or nil.
  """
  def parse_version(version_file, versions) do
    case String.split(version_file, ".") do
      [version, ext] when ext in ["avif", "webp"] ->
        if version in versions, do: version

      _ ->
        nil
    end
  end

  @doc """
  Serves a resolved version through the configured mode: `:post_image_serving`
  set to `:accel_redirect` answers with the store's internal path for nginx
  to stream (auth in the app, bytes by nginx); anything else `send_file`s the
  bytes (the sendfile syscall, no in-memory buffering).

  The `send_file` branch goes through `send_version/3`, so it carries an
  `ETag` and answers a matching `if-none-match` with a 304. That branch is the
  one production takes — `:post_image_serving` is `:send_file` there, the
  X-Accel handoff having been tried and reverted (see `config/runtime.exs`) —
  so the dormant X-Accel branch sets no validator of its own: nginx generates
  one for the file it streams and answers the conditional request itself, and
  a second `ETag` from here would only collide with it.

  Options — `:accel_path` and `:version_path` wrap the subject store's
  functions (each receives the version); `:decorate` and `:send` are
  `send_version/3`'s.
  """
  def serve(conn, version, opts) do
    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        decorate = Keyword.get(opts, :decorate, fn conn, _ext -> conn end)
        accel_path = opts[:accel_path].(version)

        conn
        |> put_cache_control()
        |> put_resp_content_type(MIME.from_path(accel_path), nil)
        |> decorate.(Path.extname(accel_path))
        |> put_resp_header("x-accel-redirect", accel_path)
        |> send_resp(200, "")

      _send_file ->
        case opts[:version_path].(version) do
          nil -> not_found(conn)
          path -> send_version(conn, path, opts)
        end
    end
  end

  @doc """
  The **derived tier** for a file on disk: the five-minute cache header, the
  `ETag`, the conditional answer, the content type and any per-response
  decoration, in one call.

  One call rather than a header helper a caller pairs with a send of its own,
  because the header and the validator are one decision: five minutes without
  an `ETag` re-sends the whole file every five minutes, where the year it
  replaced re-sent it never. Six responses used to take the header on its own
  — the two documents' previews, the crop workbench, the on-the-fly `og.jpg`
  and a clip's cover — and every one of them would have paid that.

  Options: `:decorate` (optional) receives `(conn, extname)` to add
  per-response headers, e.g. the post proxy's download filename; `:send`
  (optional) receives `(conn, path)` and sends the file, for a proxy that
  answers byte ranges (the video proxy); `:content_type` (optional) overrides
  the type read off the path.
  """
  def send_version(conn, path, opts \\ []) do
    etag = etag(path)
    conn = conn |> put_cache_control() |> put_resp_header("etag", etag)

    if ControllerHelpers.fresh?(conn, etag) do
      # A 304 carries the cache-updating fields and nothing else: the reader
      # already holds the body, its type and its filename, so the content type
      # and the `decorate` callback below are work this branch would only
      # throw away.
      send_resp(conn, 304, "")
    else
      decorate = Keyword.get(opts, :decorate, fn conn, _ext -> conn end)
      send = Keyword.get(opts, :send, &send_file(&1, 200, &2))

      conn
      |> put_resp_content_type(opts[:content_type] || MIME.from_path(path), nil)
      |> decorate.(Path.extname(path))
      |> send.(path)
    end
  end

  @doc """
  The derived tier for bytes **generated in the app** rather than read off
  disk: the post proxy's on-the-fly `og.jpg` and a clip's cover frame.

  The validator is a hash of the bytes, which are in hand by then anyway. It
  saves the send and not the derivation — but these are scraper fetches, one
  per scrape, and the alternative is sending a fresh JPEG every five minutes
  to a crawler that already has it.
  """
  def send_derived(conn, body, content_type) do
    etag = ~s("#{Integer.to_string(:erlang.phash2(body), 16)}")
    conn = conn |> put_cache_control() |> put_resp_header("etag", etag)

    if ControllerHelpers.fresh?(conn, etag) do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type(content_type, nil)
      |> send_resp(200, body)
    end
  end

  @doc """
  `private, no-store` — the counter-rule, for a response whose URL does not
  answer the same way for long: a pixelated stand-in, an owner's unreleased
  preview, a private file, and every full-resolution hand-over. Here rather
  than spelled out at each call site, for the reason `hand_over/3` gives: the
  next header must not land in only some of them.
  """
  def put_no_store(conn), do: put_resp_header(conn, "cache-control", @no_store)

  # The derived tier's header on its own, which no caller outside this module
  # may take: it is only affordable beside the validator, and `send_version/3`
  # and `send_derived/3` are the two ways to get both.
  defp put_cache_control(conn), do: put_resp_header(conn, "cache-control", @cache_control)

  # The validator: the file's size and mtime, the shape `Plug.Static` uses. A
  # hash of the URL would be cheaper and wrong — a re-derived file (a re-crop
  # writing over the same names) has to hand out a new tag, or a browser would
  # be told "not modified" for ever.
  #
  # `:raw` is not decoration. A plain `File.stat/1` routes every call through
  # the node-wide `file_server_2` process, which on this path means one message
  # round trip per picture on a page; `:raw` reads the file info in-process,
  # and `time: :posix` keeps the mtime an integer rather than a date tuple for
  # `phash2` to walk.
  #
  # `stat!` rather than a nil-tolerant branch: every caller's `version_path`
  # has already established that the file is there, so a failure here is the
  # same race `send_file` would hit on the next line, and both end as a 500.
  defp etag(path) do
    %File.Stat{size: size, mtime: mtime} = File.stat!(path, [:raw, time: :posix])
    ~s("#{Integer.to_string(:erlang.phash2({size, mtime}), 16)}")
  end

  @doc """
  Sends a **pixelated preview** (issue #1720) — the stand-in served while the
  AI image scan is still looking at a picture.

  It is the one **version** here that must not be stored at all: the real
  picture takes this URL's place within seconds, so even the five minutes a
  derived version keeps would outlive the wait. It is also never X-Accel'd —
  the traffic exists only during an open scan, and `send_file` keeps nginx out
  of a path that has to answer differently once the verdict lands. A missing
  file is the proxy's usual 404, so a swept preview reads like any other
  unknown URL.
  """
  def serve_pixelated(conn, nil), do: not_found(conn)

  def serve_pixelated(conn, path) do
    conn
    |> put_no_store()
    |> put_resp_content_type(MIME.from_path(path), nil)
    |> send_file(200, path)
  end

  @doc """
  Hands a **file** over rather than a version of a picture: `no-store`, the
  content type read off the path, `content-disposition: attachment` under
  `filename`, and the bytes.

  `no-store` rather than the derived versions' five minutes — the module doc
  says why, under the two tiers. Two responses take this route: a post photo's
  author-enabled download (#1104) and the print-quality picture a Media Kit
  exists to give away (#2083).

  Deliberately not `serve/3`. That helper's X-Accel branch resolves paths inside
  the *served* versions location, and every file that leaves this way lives in
  the private originals tree, which nginx must never learn to resolve. It is
  here rather than in each proxy because two of them now hand a file over and
  the next header must not land in only one of them.
  """
  def hand_over(conn, path, filename) do
    conn
    |> put_no_store()
    |> put_resp_content_type(MIME.from_path(path), nil)
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_file(200, path)
  end

  @doc """
  Hands a **private** file over: same shape as `hand_over/3` — `no-store`
  included, since issue #2170 gave every hand-over that header — but with the
  **stored** content type rather than one read off the path, and the name
  through the RFC 5987 pair.

  A reported file leaves the readable trees the moment a copyright case freezes
  it (`VutuvWeb.ModerationCaseController`), and a file in a message stops being
  readable when the two members stop being connected
  (`VutuvWeb.AttachmentController`, issue #2110); a copy sitting in a shared
  browser's cache would outlive either. The name goes through
  `ControllerHelpers.disposition_filename/1`, the RFC 5987 pair, so a file
  called `Papier Müller.pdf` downloads under its own name.
  """
  def hand_over_private(conn, path, filename, content_type) do
    conn
    |> put_no_store()
    |> put_resp_header(
      "content-disposition",
      "attachment; " <> VutuvWeb.ControllerHelpers.disposition_filename(filename)
    )
    |> put_resp_content_type(content_type, nil)
    |> send_file(200, path)
  end

  @doc "The uniform 404 — denied and unknown tokens are indistinguishable by design."
  def not_found(conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
