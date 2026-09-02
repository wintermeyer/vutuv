defmodule VutuvWeb.PostVideoController do
  @moduledoc """
  The authorizing video proxy (issue #1912): every byte of a post's clip is
  served through here, so the post's audience guards its video the way
  `VutuvWeb.PostImageController` guards its pictures. An unattached clip is
  its uploader's alone; denied and unknown tokens are both 404.

  ## Byte ranges

  A `<video>` element does not download a file, it asks for pieces of it —
  Safari opens with `Range: bytes=0-1` and refuses to play at all from a
  server that answers 200 to that. So this proxy answers ranges itself
  (`206 Partial Content`, `Content-Range`, `Accept-Ranges`), with
  `Plug.Conn.send_file/5`'s offset and length doing the work and no byte of
  the file passing through the VM. In the X-Accel serving mode nginx handles
  the ranges on its own.

  ## What resolves

  Only the names in `Vutuv.PostVideoStore.served_files/0` — the renditions
  and the two covers — plus `cover.jpg`, derived on the fly for link
  scrapers, and the author-only `frame-NN.jpg` stills the composer's cover
  strip shows. The original resolves on no path.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Posts.PostVideo
  alias Vutuv.PostVideoStore
  alias Vutuv.Videos
  alias VutuvWeb.ImageProxy
  alias VutuvWeb.RemoteMediaToken

  @served PostVideoStore.served_files()

  def show(conn, %{"token" => token, "file" => file} = params) do
    with what when not is_nil(what) <- parse(file),
         %PostVideo{} = video <- Videos.get_video_by_token(token),
         {source, viewer} <- reader(conn, params, token),
         true <- source != :capability or what in @served,
         true <- Videos.visible_to?(video, viewer) do
      serve(conn, video, viewer, what)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # A browser brings the session; a phone app's player brings the capability
  # the Mastodon adapter minted for exactly this clip (`VutuvWeb.RemoteMediaToken`).
  defp reader(conn, params, video_token) do
    with nil <- conn.assigns[:current_user],
         %User{} = member <-
           params[RemoteMediaToken.param()]
           |> RemoteMediaToken.post_video_viewer(video_token)
           |> RemoteMediaToken.holder() do
      {:capability, member}
    else
      %User{} = member -> {:session, member}
      _nothing_brought -> {:anonymous, nil}
    end
  end

  defp parse("cover.jpg"), do: :og

  defp parse("frame-" <> rest) do
    case Integer.parse(rest) do
      {position, ".jpg"} when position >= 0 -> {:frame, position}
      _ -> nil
    end
  end

  defp parse(file) when file in @served, do: file
  defp parse(_file), do: nil

  # The cover as JPEG for link scrapers: generated in the app, so sent
  # directly in both serving modes.
  defp serve(conn, video, _viewer, :og) do
    with %{position: position} <- Videos.cover_frame(video),
         {:ok, jpeg} <- PostVideoStore.og_jpeg(video.token, position) do
      conn
      |> ImageProxy.put_cache_control()
      |> put_resp_content_type("image/jpeg", nil)
      |> send_resp(200, jpeg)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # A still of the strip: the author's alone (an admin's too), never cached —
  # a frame the check refuses is deleted, and must not outlive that anywhere.
  defp serve(conn, video, viewer, {:frame, position}) do
    path = PostVideoStore.frame_path(video.token, position)

    if Videos.owner_or_admin?(video, viewer) and File.exists?(path) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_content_type("image/jpeg", nil)
      |> send_file(200, path)
    else
      ImageProxy.not_found(conn)
    end
  end

  defp serve(conn, video, _viewer, file) do
    conn = ImageProxy.put_cache_control(conn)

    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        accel = PostVideoStore.accel_path(video.token, file)

        conn
        |> put_resp_content_type(MIME.from_path(file), nil)
        |> put_resp_header("x-accel-redirect", accel)
        |> send_resp(200, "")

      _send_file ->
        case PostVideoStore.served_path(video.token, file) do
          nil -> ImageProxy.not_found(conn)
          path -> send_ranged(conn, path, MIME.from_path(file))
        end
    end
  end

  ## Ranges

  defp send_ranged(conn, path, content_type) do
    size = File.stat!(path).size

    conn =
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("accept-ranges", "bytes")

    case range(conn, size) do
      :whole ->
        send_file(conn, 200, path)

      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  # One range of the three shapes HTTP allows (`bytes=a-b`, `bytes=a-`,
  # `bytes=-n`); a header this does not understand is served whole, which is
  # what the spec asks. Only the first range of a list is honoured — no
  # browser's player sends more.
  defp range(conn, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] -> parse_range(spec |> String.split(",") |> hd() |> String.trim(), size)
      _ -> :whole
    end
  end

  defp parse_range(spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 -> {:ok, max(size - n, 0), size - 1}
          _ -> :whole
        end

      [first, ""] ->
        case Integer.parse(first) do
          {f, ""} when f < size -> {:ok, f, size - 1}
          {_f, ""} -> :unsatisfiable
          _ -> :whole
        end

      [first, last] ->
        with {f, ""} <- Integer.parse(first),
             {l, ""} <- Integer.parse(last),
             true <- f <= l do
          if f < size, do: {:ok, f, min(l, size - 1)}, else: :unsatisfiable
        else
          _ -> :whole
        end

      _ ->
        :whole
    end
  end
end
