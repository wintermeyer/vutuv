defmodule VutuvWeb.UploadsServingTest do
  @moduledoc """
  When `:serve_uploads_locally` is set (dev/test), the endpoint serves uploaded
  avatars/covers/screenshots straight from the storage directory, standing in
  for the nginx `/avatars/`, `/covers/` and `/screenshots/` aliases used in
  production.

  The private `originals/` tree (`Vutuv.Uploads.Originals`) must **never** be
  reachable: it has no `Plug.Static` mount here and must never get an nginx
  alias. The guard test below fails if someone mounts it.
  """
  use VutuvWeb.ConnCase, async: false

  # Mirrors the endpoint's compile-time `from:` (empty prefix -> project dir).
  @uploads_root Application.compile_env(:vutuv, :uploads_dir_prefix, "")
  @avatars_dir Path.join(@uploads_root, "avatars")
  @covers_dir Path.join(@uploads_root, "covers")
  @originals_dir Path.join(@uploads_root, "originals")

  test "serves an uploaded avatar file from disk with the AVIF content type", %{conn: conn} do
    id = System.unique_integer([:positive])
    dir = Path.join(@avatars_dir, Integer.to_string(id))
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [10, 120, 200])
    {:ok, _} = Image.write(img, Path.join(dir, "Ada King_thumb.avif"))
    on_exit(fn -> File.rm_rf(dir) end)

    conn = get(conn, "/avatars/#{id}/Ada%20King_thumb.avif")

    assert conn.status == 200
    assert byte_size(conn.resp_body) > 0
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/avif"
  end

  test "returns 404 for a missing avatar", %{conn: conn} do
    conn = get(conn, "/avatars/0/does-not-exist.avif")
    assert conn.status == 404
  end

  test "serves a fingerprinted (scheme B) avatar filename — no config change needed", %{
    conn: conn
  } do
    id = System.unique_integer([:positive])
    dir = Path.join(@avatars_dir, Integer.to_string(id))
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [10, 120, 200])
    # The on-disk name equals the URL's last segment, so the SAME static mount
    # (the production nginx `alias`) serves it with no rewrite.
    {:ok, _} = Image.write(img, Path.join(dir, "swintermeyer-medium-1a2b3c4d5e6f.avif"))
    on_exit(fn -> File.rm_rf(dir) end)

    conn = get(conn, "/avatars/#{id}/swintermeyer-medium-1a2b3c4d5e6f.avif")

    assert conn.status == 200
    assert byte_size(conn.resp_body) > 0
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/avif"
  end

  test "serves an uploaded cover photo file from disk", %{conn: conn} do
    id = System.unique_integer([:positive])
    dir = Path.join(@covers_dir, Integer.to_string(id))
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(40, 20, color: [10, 120, 200])
    {:ok, _} = Image.write(img, Path.join(dir, "Ada King_wide.avif"))
    on_exit(fn -> File.rm_rf(dir) end)

    conn = get(conn, "/covers/#{id}/Ada%20King_wide.avif")

    assert conn.status == 200
    assert byte_size(conn.resp_body) > 0
  end

  test "returns 404 for a missing cover photo", %{conn: conn} do
    conn = get(conn, "/covers/0/does-not-exist.avif")
    assert conn.status == 404
  end

  test "the private originals tree is never served", %{conn: conn} do
    id = System.unique_integer([:positive])
    dir = Path.join([@originals_dir, "avatars", Integer.to_string(id)])
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [10, 120, 200])
    {:ok, _} = Image.write(img, Path.join(dir, "original.jpg"))
    on_exit(fn -> File.rm_rf(dir) end)

    # A real file exists at this path — and still must not resolve: there is
    # no /originals mount...
    assert get(conn, "/originals/avatars/#{id}/original.jpg").status == 404

    # ...and reaching it by traversal through a served mount is rejected by
    # Plug.Static outright (a 400 in production via Plug.Exception).
    assert_raise Plug.Static.InvalidPathError, fn ->
      get(conn, "/avatars/../originals/avatars/#{id}/original.jpg")
    end
  end
end
