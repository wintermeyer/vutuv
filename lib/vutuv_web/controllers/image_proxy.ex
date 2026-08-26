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
  """

  import Plug.Conn

  @cache_control "private, max-age=31536000, immutable"

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
  bytes (the sendfile syscall, no in-memory buffering). Version URLs are
  immutable (the token is random per image), so responses carry a long
  private cache lifetime.

  Options — `:accel_path` and `:version_path` wrap the subject store's
  functions (each receives the version); `:decorate` (optional) receives
  `(conn, extname)` to add per-response headers, e.g. the post proxy's
  download filename.
  """
  def serve(conn, version, opts) do
    conn = put_cache_control(conn)
    decorate = Keyword.get(opts, :decorate, fn conn, _ext -> conn end)

    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        accel_path = opts[:accel_path].(version)

        conn
        |> put_resp_content_type(MIME.from_path(accel_path), nil)
        |> decorate.(Path.extname(accel_path))
        |> put_resp_header("x-accel-redirect", accel_path)
        |> send_resp(200, "")

      _send_file ->
        case opts[:version_path].(version) do
          nil ->
            not_found(conn)

          path ->
            conn
            |> put_resp_content_type(MIME.from_path(path), nil)
            |> decorate.(Path.extname(path))
            |> send_file(200, path)
        end
    end
  end

  @doc "The immutable private cache header every proxied image response carries."
  def put_cache_control(conn), do: put_resp_header(conn, "cache-control", @cache_control)

  @doc """
  Sends a **pixelated preview** (issue #1720) — the stand-in served while the
  AI image scan is still looking at a picture.

  It is the one response here that must not carry the immutable header above:
  the real picture takes this URL's place within seconds, so the file must not
  outlive the wait in any cache. It is also never X-Accel'd — the traffic
  exists only during an open scan, and `send_file` keeps nginx out of a path
  that has to answer differently once the verdict lands. A missing file is the
  proxy's usual 404, so a swept preview reads like any other unknown URL.
  """
  def serve_pixelated(conn, nil), do: not_found(conn)

  def serve_pixelated(conn, path) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_content_type(MIME.from_path(path), nil)
    |> send_file(200, path)
  end

  @doc "The uniform 404 — denied and unknown tokens are indistinguishable by design."
  def not_found(conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
