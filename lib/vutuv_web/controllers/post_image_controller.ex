defmodule VutuvWeb.PostImageController do
  @moduledoc """
  The authorizing image proxy: every post-image byte is served through here,
  so a post's audience (deny-model, `Vutuv.Posts.visible_to?/2`) also guards
  its images — switching a post from public to restricted locks its images
  immediately, which statically served files could never do.

  The serving mechanics (X-Accel-Redirect vs `send_file`, the version parser,
  the immutable cache header) live in `VutuvWeb.ImageProxy`, shared with the
  job-posting and organization proxies; this controller owns the post policy,
  the on-the-fly `og.jpg` and the download filename. Pending images (post not
  yet submitted) are visible to their uploader alone; denied and unknown
  tokens are both 404 — the proxy must not leak whether an image exists.

  `original.orig` is the one route by which full-resolution bytes leave
  (issue #1104), and it is closed unless the photo's author opened it for that
  photo. It is 404 by default, like everything else here — an unopened
  download and a nonexistent one look identical from outside.

  **Two ways to say who is asking, one question asked of the answer** (issue
  #1627). A browser brings the session. A phone app's image loader brings
  neither cookie nor bearer — no header we could ask for would arrive — so
  against the nil viewer it is, `Posts.visible_to?/2` was false for any post
  carrying a denial and every photo on a restricted post was a broken image in
  every client. So the Mastodon adapter mints a `VutuvWeb.RemoteMediaToken`
  capability naming the member it rendered the status for, and that member is
  the viewer here. The audience question itself is untouched and is still asked
  per request: the capability says who is at the door, never that the door is
  open, so narrowing the post shuts every URL already handed out.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias VutuvWeb.ImageProxy
  alias VutuvWeb.RemoteMediaToken

  def show(conn, %{"token" => token, "version" => version_file} = params) do
    with version when not is_nil(version) <- parse_version(version_file),
         image when not is_nil(image) <- Posts.get_image_by_token(token),
         {source, viewer} <- reader(conn, params, token),
         true <- source != :capability or served_version?(version),
         true <- allowed?(image, viewer, version) do
      serve(conn, image, version)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # Who is asking, and how they said so. One viewer, so the audience question is
  # asked exactly once — `image_visible_to?/2` looks the post up when it is not
  # preloaded, and asking twice would pay for that twice. A signed-in browser
  # never reaches the capability branch, and a request bringing nothing is the
  # anonymous reader this proxy has always served public pictures to.
  defp reader(conn, params, image_token) do
    with nil <- conn.assigns[:current_user],
         %User{} = member <-
           params[RemoteMediaToken.param()]
           |> RemoteMediaToken.post_image_viewer(image_token)
           |> RemoteMediaToken.holder() do
      {:capability, member}
    else
      %User{} = member -> {:session, member}
      _nothing_brought -> {:anonymous, nil}
    end
  end

  # Who may fetch what. Every version but the pixelated preview asks the one audience +
  # moderation question; the pixelated preview asks the mirror image of it, because it
  # exists *only* while the picture does not (`Posts.pixelated_visible_to?/2`).
  # Both are allowed here so that a URL rendered before the verdict still
  # resolves after it — `serve/3` then sends the reader to the real picture
  # rather than answering a page that is already on screen with a 404.
  defp allowed?(image, viewer, :pixelated) do
    Posts.pixelated_visible_to?(image, viewer) or Posts.image_visible_to?(image, viewer)
  end

  defp allowed?(image, viewer, _version), do: Posts.image_visible_to?(image, viewer)

  # **A capability opens the sizes a client renders, and only those.** The
  # version segment is not in the signed subject — one capability opens the
  # photo, not one file of it — so without this rule the three *derived* routes
  # below come along with it, and `original.orig` is not a size: it is the
  # full-resolution file, one swapped path segment away from any media URL that
  # leaked. The adapter names none of the three, so closing them to a capability
  # costs a client nothing.
  #
  # Only to a capability, though: `og.jpg` exists for link scrapers, which
  # arrive anonymously and must go on being served a public post's preview.
  defp served_version?(version), do: version in PostImage.versions()

  # "pixelated.avif" is the blocky stand-in served while the AI scan is still
  # looking at the photo (issue #1720) — its own name rather than a member of
  # the version whitelist, because it is not a size of the picture and nothing
  # that enumerates versions should offer it.
  #
  # "og.jpg" is the link-preview JPEG (og:image), derived on the fly rather
  # than stored; "original.orig" is the author-enabled full-resolution
  # download (issue #1104), which `serve/3` gates on that photo's own
  # `download_original` flag; "source.avif" is the author-only uncropped
  # workbench the composer's crop dialog loads. Everything else resolves
  # through the shared whitelist parser, which never resolves a stored
  # filename.
  defp parse_version("pixelated.avif"), do: :pixelated
  defp parse_version("og.jpg"), do: :og
  defp parse_version("original.orig"), do: :download
  defp parse_version("source.avif"), do: :source

  defp parse_version(version_file),
    do: ImageProxy.parse_version(version_file, PostImage.versions())

  # The pixelated preview (issue #1720). Two answers, and which one depends on where the
  # scan got to since the page was rendered:
  #
  #   * still waiting — the file, under `no-store`. It is replaced by the real
  #     picture within seconds and must not outlive that in any cache, which is
  #     the one place this proxy's year-long immutable header would be wrong.
  #   * released — a redirect to the picture itself. The pixelated preview is deleted on
  #     the verdict, so without this a dead page that lazy-loads a tile after
  #     the swap would show a broken image where the photo now is.
  defp serve(conn, image, :pixelated) do
    if ImageScans.released?(image.moderation) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> redirect(to: PostImage.url(image, "feed"))
    else
      ImageProxy.serve_pixelated(conn, existing(Vutuv.PostImageStore.pixelated_path(image.token)))
    end
  end

  # The og.jpg bytes are generated in the app (Vutuv.PostImageStore.og_jpeg/1),
  # so they are sent directly in both serving modes — there is no file for
  # nginx to accel-stream. Rare traffic: one fetch per scrape, then cached.
  defp serve(conn, image, :og) do
    case Vutuv.PostImageStore.og_jpeg(image) do
      {:ok, jpeg} ->
        conn
        |> ImageProxy.put_cache_control()
        |> put_download_name(image, "og", "jpg")
        |> put_resp_content_type("image/jpeg", nil)
        |> send_resp(200, jpeg)

      :error ->
        ImageProxy.not_found(conn)
    end
  end

  # The full-resolution download (issue #1104). Three gates, all of which must
  # hold — the audience check above has already passed at this point:
  #
  #   * the author switched this photo's download on;
  #   * a file to serve actually resolves (a format whose metadata cannot be
  #     stripped yields none rather than the untouched original — the promise
  #     fails closed, see `Vutuv.PostImageStore.download_file/1`);
  #   * `attachment`, not `inline`: this is a file handed over, and it is the
  #     one response on this proxy that should not render in the tab.
  #
  # It deliberately does not go through `ImageProxy.serve/3`: that helper's
  # X-Accel branch resolves paths inside the *served* versions location, and
  # the original must never become reachable there.
  defp serve(conn, %{download_original: false}, :download), do: ImageProxy.not_found(conn)

  defp serve(conn, image, :download) do
    case Vutuv.PostImageStore.download_file(image) do
      nil ->
        ImageProxy.not_found(conn)

      {path, ext} ->
        conn
        |> ImageProxy.put_cache_control()
        |> put_resp_content_type(MIME.from_path(path), nil)
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{filename(image, ext)}")
        )
        |> send_file(200, path)
    end
  end

  # The crop workbench: the uncropped picture at feed size, which every
  # *served* version stops being the moment a crop exists. Author-only — for
  # everyone else the full frame is exactly what the crop took away — and 404
  # like everything here, so an outsider cannot tell a guarded workbench from
  # a nonexistent one. Sent directly (no X-Accel): the file lives in the
  # private originals tree, which nginx must never learn to resolve.
  defp serve(conn, image, :source) do
    viewer = conn.assigns[:current_user]

    with true <- viewer != nil and viewer.id == image.user_id,
         path when not is_nil(path) <- Vutuv.PostImageStore.source_path(image) do
      conn
      |> ImageProxy.put_cache_control()
      |> put_resp_content_type("image/avif", nil)
      |> send_file(200, path)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  defp serve(conn, image, version) do
    ImageProxy.serve(conn, version,
      accel_path: &Vutuv.PostImageStore.accel_path(image, &1),
      version_path: &Vutuv.PostImageStore.version_path(image, &1),
      decorate: &put_download_name(&1, image, version, &2)
    )
  end

  # `nil` for a preview that is not on disk — a settled scan, a swept file, an
  # installation that turned the preview on after the picture was stored — which
  # `ImageProxy.serve_pixelated/2` answers with the proxy's usual 404.
  defp existing(path), do: if(File.exists?(path), do: path)

  # The downloaded file is named after the owner and the day the photo was
  # taken (falling back to when it was uploaded), e.g. `ada_king-2026-07-25.jpg`
  # — a name that sorts and files itself on the recipient's disk, which
  # `feed.avif` never did.
  defp filename(image, ext) do
    date =
      (image.taken_at || image.inserted_at)
      |> NaiveDateTime.to_date()
      |> Date.to_iso8601()

    handle =
      case image.user do
        %{username: slug} when is_binary(slug) -> slug
        _no_owner -> "photo"
      end

    "#{handle}-#{date}#{ext}"
  end

  # Suggest a download filename carrying the owner's handle, e.g.
  # `ada_king-feed.avif`. `inline` (not `attachment`), so it only changes the
  # name a browser proposes on "Save as", not whether the image renders inline.
  defp put_download_name(conn, image, version, ext) do
    case image.user do
      %{username: slug} when is_binary(slug) ->
        name = "#{slug}-#{version}.#{String.trim_leading(ext, ".")}"
        put_resp_header(conn, "content-disposition", ~s(inline; filename="#{name}"))

      _ ->
        conn
    end
  end
end
