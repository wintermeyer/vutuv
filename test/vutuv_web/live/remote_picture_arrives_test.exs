defmodule VutuvWeb.RemotePictureArrivesTest do
  @moduledoc """
  A picture on a cached post arrives while the reader is looking, and the card
  shows it without a reload (issue #1927) — the half issue #1801 left out.

  #1801 announced the AI gate's **verdict**, which is the end of a wait whose
  median is 97 seconds. The wait a reader actually watches starts a whole
  minute and a half earlier: the card is drawn at delivery, when the picture is
  recorded and its bytes are not here yet, and about a second later they are —
  from then on there is a mosaic preview to stand in for the picture
  (issue #1720), or the picture itself where no vision model runs. Nobody ever
  saw that mosaic on a post arriving in front of them, because nothing said the
  bytes had landed.

  The same second question is the link capture's: it reaches a cached post's
  card ~13 seconds after delivery and, until this, only on the next page load.

  `async: false` — flips `:moderate_images` and `:uploads_dir_prefix`, which the
  SQL sandbox does not roll back, and stubs the fediverse HTTP client.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Media
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Screenshot

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_picture_arrives_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    put_config(:uploads_dir_prefix, tmp)
    put_config(:moderate_images, true)

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  # A real, decodable JPEG — the store runs libvips over it, and the mosaic is
  # derived from those very pixels, so a fake binary would test nothing.
  defp jpeg_bytes do
    {:ok, image} = Image.new(64, 64, color: [40, 90, 160])
    {:ok, bytes} = Image.write(image, :memory, suffix: ".jpg")
    bytes
  end

  defp serving_bytes(bytes) do
    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.send_resp(200, bytes)
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp followed_post(user, attrs) do
    account = remote_account()

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/1"
    })

    cached_post(account, attrs)
  end

  defp attachment,
    do: %{
      "type" => "Document",
      "mediaType" => "image/jpeg",
      "url" => "https://social.example/media/#{System.unique_integer([:positive])}.jpg",
      "name" => "Ein Zug"
    }

  test "the wordless tile becomes the mosaic the moment the bytes land", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    post = followed_post(user, content_text: "Kinder.")
    [image] = Media.record_attachments(post, [attachment()], false)
    serving_bytes(jpeg_bytes())

    {:ok, view, html} = live(conn, ~p"/feed")

    # What a delivery draws: the row is here, the download is not.
    assert html =~ "data-remote-image-pending"
    refute html =~ "data-remote-image-pixelated"

    assert :ok = Media.fetch_now(image)

    html = render(view)
    assert html =~ "data-remote-image-pixelated"
    refute html =~ "data-remote-image-pending"

    # Still waiting for the verdict, so the line under the card still says what
    # the wait is — the picture has not been released, only stood in for.
    assert has_element?(view, "[data-remote-images-checking]")
    assert Repo.reload!(image).moderation == "pending"
  end

  test "a link capture reaches the post's own page with no reload", %{conn: conn, tmp: tmp} do
    # The `:assigns` half of the same question, and the other picture a card
    # draws: the capture is taken ~13 seconds after the post is cached, long
    # after a reader who followed the link from their feed has the page open.
    {conn, user} = create_and_login_user(conn)
    post = followed_post(user, content_text: "Lesenswert: https://blog.example/entry")
    {:ok, _job} = Screenshots.reconcile(post)

    {:ok, view, html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
    refute html =~ "data-screenshot-pixelated"

    Screenshots.deliver_due(force: true, capture: capture(tmp))

    # The gate still has it, so what appears is the mosaic — which is the whole
    # point: there was nothing to show before, and this is something.
    assert render(view) =~ "data-screenshot-pixelated"
    assert Repo.get_by!(PostScreenshot, remote_post_id: post.id).moderation == "pending"
  end

  # The capture worker's Chromium seam, with a real picture stored the way the
  # browser path stores one — the mosaic preview is written from those bytes.
  defp capture(tmp) do
    fn job ->
      {:ok, stored} = Screenshot.store({upload(tmp), job})
      {:ok, %{screenshot: stored, width: 400, height: 264}}
    end
  end

  defp upload(tmp) do
    path = Path.join(tmp, "capture-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(400, 264, color: [30, 90, 160])
    {:ok, _} = Image.write(image, path)
    %Plug.Upload{filename: Path.basename(path), path: path, content_type: "image/png"}
  end
end
