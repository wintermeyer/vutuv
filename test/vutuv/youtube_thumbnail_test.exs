defmodule Vutuv.YoutubeThumbnailTest do
  @moduledoc """
  YouTube video-URL recognition and the thumbnail fetch: the oEmbed existence
  check, the maxresdefault → hqdefault fallback, and the refusal of non-image
  answers. HTTP is stubbed via the `:youtube_thumbnail_req_options` `plug:`
  seam (real content-types on every stub, per the ConnTest/stub rule).
  """
  # Not async: the fetch tests set the global `:youtube_thumbnail_req_options`.
  use ExUnit.Case, async: false

  alias Vutuv.YoutubeThumbnail

  @id "EZ05e7EMOLM"

  describe "video_id/1" do
    test "watch URLs in their common spellings" do
      for url <- [
            "https://www.youtube.com/watch?v=#{@id}",
            "https://youtube.com/watch?v=#{@id}",
            "http://m.youtube.com/watch?v=#{@id}",
            "https://YouTube.com/watch?v=#{@id}&t=42s",
            "https://music.youtube.com/watch?v=#{@id}",
            "https://www.youtube.com/watch/?v=#{@id}"
          ] do
        assert YoutubeThumbnail.video_id(url) == {:ok, @id}, url
      end
    end

    test "short link, shorts, live, embed and legacy /v/ forms" do
      for url <- [
            "https://youtu.be/#{@id}",
            "https://youtu.be/#{@id}?t=10",
            "https://www.youtube.com/shorts/#{@id}",
            "https://www.youtube.com/live/#{@id}",
            "https://www.youtube.com/embed/#{@id}",
            "https://www.youtube-nocookie.com/embed/#{@id}",
            "https://www.youtube.com/v/#{@id}"
          ] do
        assert YoutubeThumbnail.video_id(url) == {:ok, @id}, url
      end
    end

    test "everything else is :error" do
      for url <- [
            # Foreign hosts, including the lookalike-suffix trick.
            "https://example.com/watch?v=#{@id}",
            "https://youtube.com.evil.example/watch?v=#{@id}",
            "https://notyoutube.com/watch?v=#{@id}",
            # YouTube pages that are not a single video.
            "https://www.youtube.com/watch",
            "https://www.youtube.com/@DevTernity",
            "https://www.youtube.com/playlist?list=PL0123456789A",
            "https://www.youtube.com/",
            # Malformed ids and malformed input (must not raise).
            "https://www.youtube.com/watch?v=short",
            "https://www.youtube.com/watch?v=%ZZ",
            "https://youtu.be/",
            "not a url at all"
          ] do
        assert YoutubeThumbnail.video_id(url) == :error, url
      end

      assert YoutubeThumbnail.video_id(nil) == :error
    end
  end

  describe "fetch/1" do
    setup do
      on_exit(fn -> Application.delete_env(:vutuv, :youtube_thumbnail_req_options) end)
      :ok
    end

    defp stub(fun), do: Application.put_env(:vutuv, :youtube_thumbnail_req_options, plug: fun)

    # fetch/1 stores nothing itself, so the "JPEG" can be any bytes as long as
    # the stub answers with the real image content-type.
    defp jpeg(conn, bytes) do
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg", nil)
      |> Plug.Conn.send_resp(200, bytes)
    end

    defp oembed_ok(conn) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"title":"stub","provider_name":"YouTube"}))
    end

    test "prefers maxresdefault when YouTube has it" do
      maxres = "/vi/#{@id}/maxresdefault.jpg"

      stub(fn conn ->
        cond do
          conn.request_path == "/oembed" -> oembed_ok(conn)
          conn.request_path == maxres -> jpeg(conn, "MAXRES")
        end
      end)

      assert YoutubeThumbnail.fetch(@id) == {:ok, "MAXRES"}
    end

    test "falls back to hqdefault when maxresdefault is missing" do
      maxres = "/vi/#{@id}/maxresdefault.jpg"
      hq = "/vi/#{@id}/hqdefault.jpg"

      stub(fn conn ->
        cond do
          conn.request_path == "/oembed" -> oembed_ok(conn)
          conn.request_path == maxres -> Plug.Conn.send_resp(conn, 404, "")
          conn.request_path == hq -> jpeg(conn, "HQ")
        end
      end)

      assert YoutubeThumbnail.fetch(@id) == {:ok, "HQ"}
    end

    test "an unknown video (oEmbed non-200) is :error and no image is fetched" do
      test_pid = self()

      stub(fn conn ->
        case conn.request_path do
          "/oembed" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(404, "Not Found")

          path ->
            send(test_pid, {:image_fetched, path})
            jpeg(conn, "SHOULD NOT BE ASKED")
        end
      end)

      assert YoutubeThumbnail.fetch(@id) == :error
      refute_received {:image_fetched, _path}
    end

    test "a non-image answer is :error (a captive portal, say)" do
      stub(fn conn ->
        case conn.request_path do
          "/oembed" ->
            oembed_ok(conn)

          _image ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, "<html>sign in</html>")
        end
      end)

      assert YoutubeThumbnail.fetch(@id) == :error
    end

    test "transport trouble is :error" do
      # Overriding url: sends every request to a closed local port.
      Application.put_env(:vutuv, :youtube_thumbnail_req_options, url: "http://127.0.0.1:1")

      assert YoutubeThumbnail.fetch(@id) == :error
    end
  end
end
