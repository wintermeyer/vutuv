defmodule Vutuv.YoutubeThumbnail do
  @moduledoc """
  The preview image YouTube itself publishes for a video, fetched instead of a
  Chromium capture: youtube.com answers every logged-out watch page with its
  cookie-consent interstitial, so a screenshot of it shows the banner, never
  the video. YouTube serves keyless static thumbnails
  for every video (`img.youtube.com/vi/<id>/…`) and a keyless oEmbed endpoint;
  the post link-screenshot worker (`Vutuv.Posts.Screenshots`) recognises a
  YouTube video URL, confirms the video exists via oEmbed, and stores the
  thumbnail through the normal screenshot uploader — fetched server-side, so a
  reader's browser never talks to Google. Any failure falls back to the
  ordinary page screenshot.

  Rides the `:generate_screenshots` gate (the worker only captures at all when
  it is on), so an air-gapped install fetches nothing. Tests stub HTTP via
  `:youtube_thumbnail_req_options` (a `plug:` seam, like the worker's probe).
  """

  alias Vutuv.SocialFeed.Http

  @req_options_key :youtube_thumbnail_req_options

  # A YouTube video id: exactly 11 URL-safe base64 characters.
  @id_regex ~r/^[A-Za-z0-9_-]{11}$/

  # The video hosts, compared after downcasing and stripping a leading `www.`
  # or `m.` — matching by the parsed host, never a URL-prefix test (see the
  # "recognising one of our own URLs" rule; a foreign URL is no different).
  @video_hosts ~w(youtube.com music.youtube.com youtube-nocookie.com)

  # The static thumbnail sizes to try, best first: maxresdefault (1280×720)
  # exists only for HD uploads, hqdefault (480×360) for every video.
  @sizes ~w(maxresdefault hqdefault)

  # A real thumbnail is a couple of hundred KB; a body running into this cap
  # (the capped collector halts receipt there) is not one.
  @max_bytes 2 * 1024 * 1024

  @doc """
  The video id in a YouTube URL: `{:ok, id}` for a watch / `youtu.be` /
  shorts / live / embed URL on any of YouTube's own hosts, `:error` for
  everything else (including YouTube pages that are not a single video — a
  channel, a playlist — which keep the ordinary page screenshot). Parsed with
  `URI.parse/1` and read by path segments, so a trailing slash, query noise
  or a fragment never changes the answer.
  """
  def video_id(url) when is_binary(url) do
    uri = URI.parse(url)
    segments = String.split(uri.path || "", "/", trim: true)
    id_for(video_host(uri.host), segments, uri.query)
  end

  def video_id(_other), do: :error

  defp video_host(nil), do: nil

  defp video_host(host) do
    host
    |> String.downcase()
    |> String.replace_prefix("www.", "")
    |> String.replace_prefix("m.", "")
  end

  # The share shortener: youtu.be/<id>.
  defp id_for("youtu.be", [id | _rest], _query), do: validate(id)

  defp id_for(host, ["watch" | _rest], query) when host in @video_hosts,
    do: validate(watch_v(query))

  defp id_for(host, [kind, id | _rest], _query)
       when host in @video_hosts and kind in ~w(shorts live embed v),
       do: validate(id)

  defp id_for(_host, _segments, _query), do: :error

  defp watch_v(nil), do: nil
  defp watch_v(query), do: URI.decode_query(query)["v"]

  defp validate(id) when is_binary(id) do
    if Regex.match?(@id_regex, id), do: {:ok, id}, else: :error
  end

  defp validate(_missing), do: :error

  @doc """
  The best available thumbnail for a video id: `{:ok, jpeg_bytes}` or
  `:error`. Two or three requests: the oEmbed endpoint first — a keyless
  existence check, so a deleted or private video reports `:error` (and the
  caller screenshots the page) instead of storing YouTube's grey placeholder
  tile — then `maxresdefault.jpg` (HD uploads only) with `hqdefault.jpg`
  (always present) as the fallback.
  """
  def fetch(video_id) do
    with :ok <- confirm_video(video_id) do
      Enum.find_value(@sizes, :error, &thumbnail(video_id, &1))
    end
  end

  defp confirm_video(video_id) do
    watch_url = "https://www.youtube.com/watch?v=#{video_id}"
    query = URI.encode_query(url: watch_url, format: "json")

    case get("https://www.youtube.com/oembed?" <> query) do
      {:ok, %Req.Response{status: 200}} -> :ok
      _other -> :error
    end
  end

  defp thumbnail(video_id, size) do
    case get("https://img.youtube.com/vi/#{video_id}/#{size}.jpg") do
      {:ok, %Req.Response{status: 200, body: bytes} = resp}
      when is_binary(bytes) and bytes != "" ->
        if image?(resp) and byte_size(bytes) < @max_bytes, do: {:ok, bytes}

      _other ->
        nil
    end
  end

  defp image?(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [type | _rest] -> String.starts_with?(type, "image/")
      [] -> false
    end
  end

  defp get(url) do
    [
      url: url,
      receive_timeout: 10_000,
      connect_options: [timeout: 5_000],
      retry: false,
      # The bodies are a JSON we never read and a JPEG stored verbatim, so Req
      # must not decode either (`into:` does not disable the decode step).
      decode_body: false,
      into: Vutuv.Http.capped_collector(@max_bytes),
      headers: [{"user-agent", Http.user_agent()}]
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
  end
end
