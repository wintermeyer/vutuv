defmodule VutuvWeb.PressKitImageControllerTest do
  @moduledoc """
  The authorizing press-kit proxy (issue #2083). Three claims: the row is the
  off switch, so a picture the AI gate has not released is its owner's alone and
  a stranger's request is indistinguishable from one for a token that does not
  exist; the file addresses hand over a *file*, as an attachment and with
  `nosniff`, which is what makes it safe to let a vector logo out at all; and no
  URL resolves anything but the versions its shelf actually has.

  Not async, and it flips two application env keys for its lifetime:
  `:uploads_dir_prefix` (read by every uploader) and `:moderate_images` (read by
  `Vutuv.Moderation.ImageScans.initial_state/0` and every store that asks
  whether to quarantine). Both are global and the SQL sandbox does not roll them
  back.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.PressKit
  alias Vutuv.Repo

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_press_proxy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    put_config(:moderate_images, true)
    on_exit(fn -> File.rm_rf(tmp) end)

    {owner_conn, owner} = create_and_login_user(conn)
    {:ok, tmp: tmp, owner: owner, owner_conn: owner_conn}
  end

  defp anonymous, do: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})

  defp photo!(owner, tmp, attrs \\ %{}) do
    path = Path.join(tmp, "shot-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
    {:ok, _} = Image.write(img, path)

    {:ok, image} =
      PressKit.create(owner, owner, {path, "shot.jpg"}, Map.merge(confirmed(), attrs))

    image
  end

  defp svg_logo!(owner, tmp) do
    path = Path.join(tmp, "mark-#{System.unique_integer([:positive])}.svg")

    File.write!(
      path,
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="240" height="80">) <>
        ~s(<rect width="240" height="80" fill="#0a5"/></svg>)
    )

    {:ok, image} =
      PressKit.create(
        owner,
        owner,
        {path, "mark.svg"},
        Map.merge(confirmed(), %{"logo" => "true"})
      )

    image
  end

  defp confirmed, do: %{"rights_confirmed" => "true", "credit" => "Foto: Ada King"}

  defp release!(image), do: Repo.update!(Ecto.Changeset.change(image, moderation: "approved"))

  describe "who gets the bytes" do
    test "a released picture is everyone's, under nosniff", %{owner: owner, tmp: tmp} do
      photo = release!(photo!(owner, tmp))

      conn = get(anonymous(), PressKit.url(photo, "large"))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/avif"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "one still waiting is the owner's alone, and a stranger cannot tell it exists",
         %{owner: owner, owner_conn: owner_conn, tmp: tmp} do
      photo = photo!(owner, tmp)
      assert photo.moderation == "pending"

      assert get(owner_conn, PressKit.url(photo, "large")).status == 200
      assert get(anonymous(), PressKit.url(photo, "large")).status == 404

      # Byte for byte the answer an unknown token gets.
      assert get(anonymous(), "/system/press_kit/nosuchtoken/large.avif").status == 404
    end

    test "a frozen picture is nobody's, its owner included",
         %{owner: owner, owner_conn: owner_conn, tmp: tmp} do
      photo =
        owner
        |> photo!(tmp)
        |> release!()
        |> Ecto.Changeset.change(frozen_at: NaiveDateTime.utc_now(:second))
        |> Repo.update!()

      assert get(owner_conn, PressKit.url(photo, "large")).status == 404
      assert get(anonymous(), PressKit.url(photo, "large")).status == 404
    end
  end

  describe "the file a journalist takes away" do
    test "arrives as an attachment named after the handle, cleaned",
         %{owner: owner, tmp: tmp} do
      photo = release!(photo!(owner, tmp))

      conn = get(anonymous(), PressKit.download_url(photo))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition == ~s(attachment; filename="#{owner.username}-press-1.jpg")
    end

    test "a vector logo leaves only as a saved file, never something to render",
         %{owner: owner, tmp: tmp} do
      logo = release!(svg_logo!(owner, tmp))

      conn = get(anonymous(), PressKit.download_url(logo))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
      # The two headers that together mean "save this, do not render it, and do
      # not guess": an SVG rendered inline on our own origin is a script there.
      # `attachment` is this controller's; the `nosniff` is the router's
      # `put_secure_browser_headers` (measured: removing a copy from the
      # controller changed no header here). Asserted anyway, because a route
      # moved out of the `:browser` pipeline would lose it silently.
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert [~s(attachment; filename="#{owner.username}-logo-1.svg")] ==
               get_resp_header(conn, "content-disposition")

      assert conn.resp_body =~ "<svg"
    end

    test "the PNG rendering stands beside the vector, and only for a logo",
         %{owner: owner, tmp: tmp} do
      logo = release!(svg_logo!(owner, tmp))
      photo = release!(photo!(owner, tmp))

      conn = get(anonymous(), PressKit.png_download_url(logo))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert <<137, "PNG\r\n", 26, 10, _rest::binary>> = conn.resp_body

      assert get(anonymous(), PressKit.png_download_url(photo)).status == 404
    end
  end

  describe "what a URL may name" do
    test "only the versions the shelf has, and never a stored file",
         %{owner: owner, tmp: tmp} do
      photo = release!(photo!(owner, tmp))
      logo = release!(svg_logo!(owner, tmp))

      assert get(anonymous(), PressKit.url(photo, "xl")).status == 200
      # A logo has two versions; the lightbox size is not one of them.
      assert get(anonymous(), PressKit.url(logo, "xl")).status == 404

      for name <- ~w(original.orig original.jpg cleaned.jpg download.svg ../../etc/passwd) do
        assert get(anonymous(), "/system/press_kit/#{photo.token}/#{name}").status == 404
      end
    end

    test "a token belonging to another kind is not a press picture",
         %{owner: owner, tmp: tmp} do
      photo = release!(photo!(owner, tmp))
      Repo.update!(Ecto.Changeset.change(photo, kind: "post_image"))

      assert get(anonymous(), PressKit.url(photo, "large")).status == 404
    end
  end
end
