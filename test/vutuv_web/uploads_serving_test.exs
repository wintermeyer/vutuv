defmodule VutuvWeb.UploadsServingTest do
  @moduledoc """
  When `:serve_uploads_locally` is set (dev/test), the endpoint serves uploaded
  avatars/screenshots straight from the storage directory, standing in for the
  nginx `/avatars/` and `/screenshots/` aliases used in production.
  """
  use VutuvWeb.ConnCase, async: false

  # Mirrors the endpoint's compile-time `from:` (empty prefix -> project dir).
  @avatars_dir Path.join(Application.compile_env(:vutuv, :uploads_dir_prefix, ""), "avatars")

  test "serves an uploaded avatar file from disk", %{conn: conn} do
    id = System.unique_integer([:positive])
    dir = Path.join(@avatars_dir, Integer.to_string(id))
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [10, 120, 200])
    {:ok, _} = Image.write(img, Path.join(dir, "Ada King_thumb.jpg"))
    on_exit(fn -> File.rm_rf(dir) end)

    conn = get(conn, "/avatars/#{id}/Ada%20King_thumb.jpg")

    assert conn.status == 200
    assert byte_size(conn.resp_body) > 0
  end

  test "returns 404 for a missing avatar", %{conn: conn} do
    conn = get(conn, "/avatars/0/does-not-exist.jpg")
    assert conn.status == 404
  end
end
