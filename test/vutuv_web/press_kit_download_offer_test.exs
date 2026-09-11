defmodule VutuvWeb.PressKitDownloadOfferTest do
  @moduledoc """
  Which downloads the Media Kit offers, and the one case that made the question
  worth asking (issue #2182): a logo stored **before** the SVG cleaning shipped,
  which the cleaner now refuses. Its size had already disappeared from the page
  and from the structured data — `Vutuv.PressKit.download_bytes/1` measures the
  file the route hands over, and there is none — while the Download button
  stayed and answered 404 to whoever pressed it.

  So the module asserts a pair rather than a state: the links a **real** upload
  offers, and then the same page once its stored original has been replaced by
  markup the cleaner will not clean. The second half is the regression; the
  first is what keeps it from passing by simply never drawing a download.

  It uploads real files, and is therefore not async: the upload path writes them
  and `:uploads_dir_prefix` is global. Rows inserted by
  `Vutuv.ImageHelpers.put_press_picture/2` have no files at all and so offer no
  download either — `VutuvWeb.PressKitControllerTest` holds that side.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.PressKit
  alias Vutuv.PressKitStore
  alias Vutuv.Repo

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_press_offer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    user = insert_activated_user(username: "presse.person", first_name: "Ada", last_name: "King")

    {:ok,
     conn: conn,
     user: user,
     tmp: tmp,
     logo: upload_logo(user, tmp),
     photo: upload_photo(user, tmp)}
  end

  defp upload_photo(user, tmp) do
    path = Path.join(tmp, "portrait-#{System.unique_integer([:positive])}.jpg")
    {:ok, image} = Image.new(600, 400, color: [200, 40, 40])
    {:ok, _} = Image.write(image, path)

    {:ok, row} =
      PressKit.create(user, user, {path, "portrait.jpg"}, %{
        "rights_confirmed" => "true",
        "credit" => "Foto: Rea Fotografin"
      })

    Repo.update!(Ecto.Changeset.change(row, moderation: "approved"))
  end

  defp upload_logo(user, tmp) do
    path = Path.join(tmp, "wordmark-#{System.unique_integer([:positive])}.svg")

    File.write!(path, """
    <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="400" viewBox="0 0 1200 400">
      <rect x="40" y="120" width="1120" height="160" fill="#123456" />
    </svg>
    """)

    {:ok, image} =
      PressKit.create(user, user, {path, "wordmark.svg"}, %{
        "logo" => "true",
        "rights_confirmed" => "true",
        "alt" => "Wortmarke"
      })

    Repo.update!(Ecto.Changeset.change(image, moderation: "approved"))
  end

  # What a logo stored before the cleaning shipped is, from the store's point of
  # view: the same row, with an original the cleaner refuses. A script handler
  # is the one #2181 measured, and it is refused by the cleaner rather than by
  # the renderer — so the PNG rendering beside it still rasterises, which is
  # exactly the asymmetry the page has to draw.
  defp spoil_original!(logo) do
    original = PressKitStore.original_path(logo.token)

    File.write!(original, """
    <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="400" viewBox="0 0 1200 400"
         onload="fetch\('https://tracker.example/beacon'\)">
      <rect x="40" y="120" width="1120" height="160" fill="#123456" />
    </svg>
    """)

    # The cached cleaned copy is what a first download wrote; without it the
    # refusal never happens and the test measures nothing.
    File.rm_rf!(Path.join(Path.dirname(original), "cleaned.svg"))
    logo
  end

  defp page(conn, user), do: conn |> get(~p"/#{user}/media-kit") |> html_response(200)

  defp doc_logo(conn, user) do
    body = conn |> get("/#{user.username}/media-kit.json") |> Map.fetch!(:resp_body)
    [logo] = Jason.decode!(body)["logos"]
    logo
  end

  defp schema_logo(html) do
    html
    |> json_ld("CollectionPage")
    |> Map.fetch!("associatedMedia")
    |> Enum.find(&(&1["encodingFormat"] == "image/svg+xml"))
  end

  describe "a logo whose file is really there" do
    test "offers both its formats", %{conn: conn, user: user, logo: logo, photo: photo} do
      html = page(conn, user)

      assert html =~ "/system/press_kit/#{logo.token}/download.orig"
      assert html =~ "/system/press_kit/#{logo.token}/download.png"
      assert html =~ "/system/press_kit/#{photo.token}/download.orig"
    end

    # The two button labels the fileless fixtures elsewhere can no longer draw,
    # asserted by name because a `gettext.extract --merge` fuzzy-fill puts
    # confident German nonsense in a msgid nobody looks at again.
    test "and says so in German", %{conn: conn, user: user} do
      html =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/#{user}/media-kit")
        |> html_response(200)

      assert html =~ "Foto herunterladen"
      assert html =~ "SVG herunterladen"
      assert html =~ "PNG herunterladen"
    end

    test "and both addresses really answer", %{conn: conn, logo: logo} do
      assert get(conn, PressKit.download_url(logo)).status == 200
      assert get(conn, PressKit.png_download_url(logo)).status == 200
    end

    test "names the file to a machine, with its length", %{conn: conn, user: user, logo: logo} do
      assert %{"contentUrl" => url, "contentSize" => size} = schema_logo(page(conn, user))
      assert url =~ "/system/press_kit/#{logo.token}/download.orig"
      assert String.to_integer(size) > 0

      entry = doc_logo(conn, user)
      assert entry["download_url"] =~ "download.orig"
      assert entry["png_download_url"] =~ "download.png"
      assert entry["size_bytes"] > 0
    end
  end

  describe "a logo the cleaner now refuses" do
    setup %{logo: logo}, do: {:ok, logo: spoil_original!(logo)}

    test "the file it cannot hand over really is a 404", %{conn: conn, logo: logo} do
      assert PressKit.download_bytes(logo) == nil
      assert get(conn, PressKit.download_url(logo)).status == 404
    end

    test "so the page draws no button for it, and keeps the PNG", %{
      conn: conn,
      user: user,
      logo: logo
    } do
      html = page(conn, user)

      refute html =~ "/system/press_kit/#{logo.token}/download.orig"
      assert html =~ "/system/press_kit/#{logo.token}/download.png"
      # The variant is still on the page — a missing file is not a missing
      # logo, and the PNG beside it is what a journalist leaves with.
      assert html =~ "Wortmarke"
    end

    test "and neither does the structured data", %{conn: conn, user: user} do
      logo = schema_logo(page(conn, user))

      refute Map.has_key?(logo, "contentUrl")
      refute Map.has_key?(logo, "contentSize")
      assert logo["thumbnailUrl"] =~ "thumb"
    end

    test "and neither does the agent document", %{conn: conn, user: user} do
      entry = doc_logo(conn, user)

      refute Map.has_key?(entry, "download_url")
      refute Map.has_key?(entry, "size_bytes")
      # The PNG is a rasterisation of the same upload, so the cleaner's verdict
      # never reaches it — and its pixel size travels with it.
      assert entry["png_download_url"] =~ "download.png"
      assert entry["png_width"] == 1600
    end
  end
end
