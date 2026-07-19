defmodule VutuvWeb.PendingImageTest do
  @moduledoc """
  The web-facing half of AI image-moderation limbo: the owner's quarantine
  preview route serves the pending avatar/cover to the owner alone, while
  every public surface (profile HTML, the OG `avatar.jpg`, the vCard, the
  agent docs) answers as if the image did not exist.
  """
  # Not async: flips the global :moderate_images + :uploads_dir_prefix env.
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Accounts

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_pending_#{System.unique_integer([:positive])}")
    prev_dir = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
    Application.put_env(:vutuv, :moderate_images, true)

    on_exit(fn ->
      File.rm_rf(tmp)
      Application.put_env(:vutuv, :moderate_images, false)

      if prev_dir,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev_dir),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    owner = insert(:activated_user)
    owner_email = insert(:email, user: owner)

    src = Path.join(System.tmp_dir!(), "pending_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)

    upload = %Plug.Upload{filename: "photo.jpg", path: src, content_type: "image/jpeg"}
    {:ok, owner} = Accounts.update_user(owner, %{avatar: upload})
    assert owner.avatar_moderation == "pending"

    {:ok, conn: conn, owner: owner, owner_email: owner_email.value}
  end

  describe "the owner's quarantine preview (/settings/pending_image)" do
    test "serves the owner their own pending avatar", %{conn: conn, owner_email: owner_email} do
      conn =
        conn
        |> login_via_pin(owner_email)
        |> get(~p"/settings/pending_image/avatar/medium")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/avif"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "another member gets a 404 (the route only ever serves your own)", %{conn: conn} do
      other = insert(:activated_user)
      other_email = insert(:email, user: other)

      conn =
        conn
        |> login_via_pin(other_email.value)
        |> get(~p"/settings/pending_image/avatar/medium")

      assert conn.status == 404
    end

    test "404 for unknown kinds/versions and once nothing is pending", %{
      conn: conn,
      owner_email: owner_email
    } do
      conn = login_via_pin(conn, owner_email)

      assert get(conn, "/settings/pending_image/avatar/original").status == 404
      assert get(conn, "/settings/pending_image/evil/medium").status == 404
      assert get(conn, "/settings/pending_image/cover/wide").status == 404
    end
  end

  describe "public surfaces during limbo" do
    test "the profile shows the initials tile to a visitor, the preview + pill to the owner",
         %{conn: conn, owner: owner, owner_email: owner_email} do
      visitor_html = conn |> get("/#{owner.username}") |> html_response(200)
      refute visitor_html =~ "/avatars/#{owner.id}/"
      refute visitor_html =~ "data-image-pending-pill"

      owner_html =
        conn
        |> login_via_pin(owner_email)
        |> get("/#{owner.username}")
        |> html_response(200)

      assert owner_html =~ "/settings/pending_image/avatar/medium"
      assert owner_html =~ "data-image-pending-pill"
    end

    test "the OG avatar.jpg endpoint refuses to leak the unreleased original", %{
      conn: conn,
      owner: owner
    } do
      assert conn |> get("/#{owner.username}/avatar.jpg") |> Map.fetch!(:status) == 404
    end

    test "the vCard falls back to the default image", %{conn: conn, owner: owner} do
      vcf = conn |> get("/#{owner.username}.vcf") |> response(200)
      refute vcf =~ "PHOTO;ENCODING=b"
    end

    test "the agent-doc siblings carry no avatar URL", %{conn: conn, owner: owner} do
      json = conn |> get("/#{owner.username}.json") |> response(200)
      refute json =~ "/avatars/#{owner.id}/"
    end
  end
end
