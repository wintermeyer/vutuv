defmodule VutuvWeb.BinaryContentTypeTest do
  @moduledoc """
  A binary response must not claim a character set.

  `Plug.Conn.put_resp_content_type/3` appends `; charset=utf-8` unless the third
  argument is `nil`, so the natural two-argument call labels a PNG
  `image/png; charset=utf-8`. Nothing in the app reads that parameter, but the
  clients that fetch these URLs are not browsers: link-preview fetchers,
  fediverse servers and mail clients all sniff the content type, and a binary
  body carrying a text parameter is the kind of thing a strict one rejects.

  The scan below is the guard, because the wrong form is the shorter one and
  reads perfectly fine in review.
  """
  use VutuvWeb.ConnCase, async: true

  # Types whose body is bytes, not text. `MIME.from_path/1` resolves an uploaded
  # file's own type (avatars, post images, qualification documents) and is always
  # binary here.
  @binary_arg ~r/"(image|video|audio|application\/pdf|application\/octet-stream)\/|MIME\.from_path/

  describe "source scan" do
    test "every binary put_resp_content_type/2 call passes nil as the charset" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _no} -> binary_content_type_call?(line) end)
          |> Enum.reject(fn {line, _no} -> line =~ ~r/,\s*nil\)/ end)
          |> Enum.map(fn {line, no} -> "#{file}:#{no}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             """
             These responses send bytes but label them with a charset. Pass `nil`
             as the third argument to `put_resp_content_type/3`:

             #{Enum.join(offenders, "\n")}
             """
    end
  end

  describe "the Open Graph card" do
    test "GET /og-card.png answers a bare image/png", %{conn: conn} do
      conn = get(conn, "/og-card.png")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
    end
  end

  defp binary_content_type_call?(line) do
    String.contains?(line, "put_resp_content_type(") and line =~ @binary_arg
  end
end
