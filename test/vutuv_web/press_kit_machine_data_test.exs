defmodule VutuvWeb.PressKitMachineDataTest do
  @moduledoc """
  What the Media Kit tells a **machine** about a picture: the page's schema.org
  block (issue #2140) and the title every agent format gives a picture whose
  owner typed no label (issue #2142).

  Unlike `VutuvWeb.PressKitControllerTest`, which inserts rows, this module
  **uploads real files** — the whole point of #2140 is that the numbers in the
  markup must be the numbers of the file the download hands over, and a row
  whose `size_bytes` was typed into a fixture cannot tell a right answer from a
  wrong one. The photo carries a JPEG comment segment on purpose, so the
  metadata strip really does change the file's length: without it the wrong
  number and the right one are the same number and the test proves nothing.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.PressKit
  alias Vutuv.Repo
  alias VutuvWeb.UI

  # Long enough that the stripped file is visibly shorter, and exactly the kind
  # of thing a press download must never carry.
  @comment "Kamera-Seriennummer, GPS-Position und Aufnahmesoftware, die keine Redaktion je sehen soll."

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_media_kit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    user =
      insert_activated_user(username: "presse.person", first_name: "Bea", last_name: "Bildnis")

    photo =
      upload(user, photo_file(tmp), %{
        "credit" => "Foto: Rea Reportage",
        "alt" => "Bea Bildnis am Schreibtisch",
        "caption" => "**Bea Bildnis** in ihrem Bonner Büro, ein *Hochformat* ist erlaubt."
      })

    logo = upload(user, svg_file(tmp), %{"logo" => "true"})

    {:ok, conn: conn, user: user, photo: photo, logo: logo}
  end

  defp upload(user, source, attrs) do
    {:ok, image} =
      PressKit.create(user, user, source, Map.merge(%{"rights_confirmed" => "true"}, attrs))

    Repo.update!(Ecto.Changeset.change(image, moderation: "approved"))
  end

  defp photo_file(tmp) do
    path = Path.join(tmp, "portrait-#{System.unique_integer([:positive])}.jpg")
    # Small on purpose: `VutuvWeb.UI.file_size/1` rounds to kB past 999 bytes,
    # and at that resolution the upload's size and the download's read the same
    # — the page's facts line could not tell a right answer from a wrong one.
    {:ok, image} = Image.new(60, 40, color: [200, 40, 40])
    {:ok, _} = Image.write(image, path)

    <<0xFF, 0xD8, rest::binary>> = File.read!(path)
    segment = <<0xFF, 0xFE, byte_size(@comment) + 2::16, @comment::binary>>
    File.write!(path, <<0xFF, 0xD8, segment::binary, rest::binary>>)

    {path, "portrait.jpg"}
  end

  defp svg_file(tmp) do
    path = Path.join(tmp, "wordmark-#{System.unique_integer([:positive])}.svg")

    File.write!(path, """
    <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="400" viewBox="0 0 1200 400">
      <rect x="40" y="120" width="1120" height="160" fill="#123456" />
    </svg>
    """)

    {path, "wordmark.svg"}
  end

  # One `ImageObject` out of the page's schema.org block, read rather than
  # grepped — see `VutuvWeb.HTMLHelpers.json_ld/2` for why grepping cannot work.
  defp media_for(html, format) do
    html
    |> json_ld("CollectionPage")
    |> Map.fetch!("associatedMedia")
    |> Enum.find(&(&1["encodingFormat"] == format))
  end

  defp delivered_bytes(conn, path), do: conn |> get(path) |> Map.fetch!(:resp_body) |> byte_size()

  describe "the schema.org block describes the file it links to (issue #2140)" do
    test "a photo's contentUrl, contentSize and format are the download's",
         %{conn: conn, user: user, photo: photo} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)
      media = media_for(html, "image/jpeg")

      download = ~p"/system/press_kit/#{photo.token}/download.orig"
      assert media["contentUrl"] =~ download

      delivered = delivered_bytes(conn, download)

      # Calibration: without a metadata block to remove, the stored size and the
      # delivered size are the same number and this test could not fail.
      assert delivered < photo.size_bytes

      assert media["contentSize"] == Integer.to_string(delivered)
      assert media["width"] == photo.width
      assert media["height"] == photo.height
    end

    test "the caption reaches a machine as prose, not as Markdown",
         %{conn: conn, user: user} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)
      media = media_for(html, "image/jpeg")

      assert media["caption"] ==
               "Bea Bildnis in ihrem Bonner Büro, ein Hochformat ist erlaubt."

      refute media["caption"] =~ "**"
      refute media["caption"] =~ "*Hochformat*"
    end

    test "a vector logo claims no pixel size and its own byte count",
         %{conn: conn, user: user, logo: logo} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)
      media = media_for(html, "image/svg+xml")

      download = ~p"/system/press_kit/#{logo.token}/download.orig"
      assert media["contentUrl"] =~ download
      assert media["contentSize"] == Integer.to_string(delivered_bytes(conn, download))

      # The width and height on the row are the rasterisation's, which is the
      # PNG rendering beside the vector — not the vector, which has no pixels.
      refute Map.has_key?(media, "width")
      refute Map.has_key?(media, "height")
    end
  end

  describe "the page's own file facts (issue #2140)" do
    test "a vector logo's pixel size is named as its PNG rendering's",
         %{conn: conn, user: user, logo: logo} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)

      assert html =~ "PNG #{logo.width} × #{logo.height}"
      refute html =~ ~s(data-press-facts>#{logo.width} × #{logo.height})
    end

    test "a photo's file size is the download's, not the upload's",
         %{conn: conn, user: user, photo: photo} do
      html = conn |> get(~p"/#{user}/media-kit") |> html_response(200)
      delivered = delivered_bytes(conn, ~p"/system/press_kit/#{photo.token}/download.orig")

      # Calibration: the two numbers must still round to different words, or
      # this assertion holds whichever of them the page prints.
      assert UI.file_size(delivered) != UI.file_size(photo.size_bytes)

      assert html =~ "#{photo.width} × #{photo.height} · #{UI.file_size(delivered)}"
      refute html =~ "· #{UI.file_size(photo.size_bytes)}"
    end
  end

  describe "an unlabelled logo is a logo in every format (issue #2142)" do
    test "the four siblings title it Logo variant, never Press picture",
         %{conn: conn, user: user} do
      md = conn |> get(~p"/#{user}/media-kit.md") |> Map.fetch!(:resp_body)
      txt = conn |> get(~p"/#{user}/media-kit.txt") |> Map.fetch!(:resp_body)
      json = conn |> get(~p"/#{user}/media-kit.json") |> Map.fetch!(:resp_body)
      xml = conn |> get(~p"/#{user}/media-kit.xml") |> Map.fetch!(:resp_body)

      assert md =~ "[Logo variant]("
      refute md =~ "[Press picture]("

      assert txt =~ "- Logo variant\n"
      refute txt =~ "- Press picture\n"

      assert [logo] = Jason.decode!(json)["logos"]
      assert logo["label"] == "Logo variant"

      assert xml =~ "<label>Logo variant</label>"
    end

    test "and the German ones say Logo-Variante", %{conn: conn, user: user} do
      md = conn |> get(~p"/#{user}/media-kit.md?lang=de") |> Map.fetch!(:resp_body)
      txt = conn |> get(~p"/#{user}/media-kit.txt?lang=de") |> Map.fetch!(:resp_body)

      assert md =~ "[Logo-Variante]("
      refute md =~ "[Pressebild]("

      assert txt =~ "- Logo-Variante\n"
      refute txt =~ "- Pressebild\n"
    end
  end
end
