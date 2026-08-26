defmodule VutuvWeb.PostImagePixelatedTest do
  @moduledoc """
  The pixelated preview that stands in for a photo while the AI scan is looking at it
  (issue #1720): a real, separately stored file — never a filter over the
  picture — served to readers who may not see the picture itself, and gone
  again the moment the verdict lands.

  Not async: flips the global `:moderate_images` (read by
  `Vutuv.Moderation.ImageScans.enabled?/0`, and through it by every uploader
  and by `Vutuv.Moderation.Pixelation.write_if_enabled/2`),
  `:image_pixelation_window_seconds` (read by `Vutuv.Moderation.Pixelation`) and
  `:uploads_dir_prefix`.
  """
  use VutuvWeb.ConnCase, async: false

  import Ecto.Query

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.PostImageStore
  alias Vutuv.Posts
  alias Vutuv.Repo

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_pixelated_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    put_config(:uploads_dir_prefix, tmp)
    put_config(:moderate_images, true)

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  # `fetch_env/2` and not `get_env/2`: a key that is absent must come back
  # absent, or the restore writes `nil` in as a real value and poisons every
  # later reader's default.
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

  # A 2px checkerboard: the finest detail an image can carry, and a source
  # whose "did the detail survive" question has one number for an answer (its
  # standard deviation, 127.5).
  defp checkerboard!(tmp) do
    {:ok, tile} =
      VipsImage.new_from_binary(
        <<0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0>>,
        2,
        2,
        3,
        :VIPS_FORMAT_UCHAR
      )

    {:ok, checker} = Operation.replicate(tile, 160, 160)
    path = Path.join(tmp, "checker-#{System.unique_integer([:positive])}.png")
    {:ok, _} = Image.write(checker, path)
    path
  end

  defp stddev(path) do
    {:ok, image} = Image.open(path)
    {:ok, deviation} = Operation.deviate(image)
    deviation
  end

  defp post_with_held_photo!(tmp) do
    author = insert(:user, email_confirmed?: true)
    {:ok, image} = Posts.create_pending_image(author, checkerboard!(tmp), "photo.png")
    assert image.moderation == "pending"

    {:ok, post} = Posts.create_post(author, %{body: "pic", image_ids: [image.id]})

    {post, Repo.reload!(image), author}
  end

  defp approve!(image) do
    scan =
      Repo.one!(from(s in ImageScan, where: s.kind == "post_image" and s.subject_id == ^image.id))

    assert :ok = ImageSubjects.apply_approved(scan)
  end

  describe "the served stand-in" do
    test "is the picture's own pixelated preview, and carries none of its detail", %{tmp: tmp} do
      {_post, image, _author} = post_with_held_photo!(tmp)

      pixelated = PostImageStore.pixelated_path(image.token)
      assert File.exists?(pixelated)

      # The calibration that makes the pixelated preview figure mean something: the same
      # pixels, the same encoder, in a version that is *not* a pixelated preview keep the
      # source's own 127.5. So the near-zero next to it is the shrink having
      # thrown the detail away, not the codec smoothing everything.
      assert stddev(PostImageStore.version_path(image, "feed")) > 100
      assert stddev(pixelated) < 5
    end

    test "is not written at all where nothing waits for a verdict", %{tmp: tmp} do
      put_config(:moderate_images, false)

      author = insert(:user, email_confirmed?: true)
      {:ok, image} = Posts.create_pending_image(author, checkerboard!(tmp), "photo.png")

      assert image.moderation == "approved"
      refute File.exists?(PostImageStore.pixelated_path(image.token))
    end
  end

  describe "the proxy" do
    test "serves a stranger the pixelated preview and no version of the picture", %{
      conn: conn,
      tmp: tmp
    } do
      {_post, image, _author} = post_with_held_photo!(tmp)

      pixelated = get(conn, "/post_images/#{image.token}/pixelated.avif")

      assert pixelated.status == 200
      assert get_resp_header(pixelated, "content-type") |> hd() =~ "image/avif"
      # The one response on this proxy that must not carry its year-long
      # immutable header: the real picture takes this URL's place in seconds.
      assert get_resp_header(pixelated, "cache-control") == ["private, no-store"]

      for version <- ~w(thumb feed large xl) do
        assert conn |> get("/post_images/#{image.token}/#{version}.avif") |> Map.fetch!(:status) ==
                 404
      end
    end

    test "sends a reader to the picture once the scan has released it", %{conn: conn, tmp: tmp} do
      {_post, image, _author} = post_with_held_photo!(tmp)
      approve!(image)

      redirected = get(conn, "/post_images/#{image.token}/pixelated.avif")

      # A page rendered before the verdict still holds stand-in URLs; answering
      # them with a 404 would draw a broken image where the photo now is.
      assert redirected_to(redirected) == "/post_images/#{image.token}/feed.avif"
      assert conn |> get("/post_images/#{image.token}/feed.avif") |> Map.fetch!(:status) == 200
    end

    test "drops the pixelated preview file on the verdict", %{tmp: tmp} do
      {_post, image, _author} = post_with_held_photo!(tmp)
      assert File.exists?(PostImageStore.pixelated_path(image.token))

      approve!(image)

      refute File.exists?(PostImageStore.pixelated_path(image.token))
    end
  end

  describe "the window" do
    test "stops offering the pixelated preview once the wait has run past it", %{tmp: tmp} do
      {_post, image, _author} = post_with_held_photo!(tmp)

      assert Posts.image_pixelated_url(image) == "/post_images/#{image.token}/pixelated.avif"

      # Same picture, same file, one hour and a minute of waiting: the card
      # falls back to the grey tile rather than leaving a pixelated preview of an unvetted
      # picture standing on a public page indefinitely.
      aged = %{image | inserted_at: NaiveDateTime.add(image.inserted_at, -3_660, :second)}
      assert Posts.image_pixelated_url(aged) == nil
    end

    test "is off entirely at 0, which is how an installation opts out", %{tmp: tmp} do
      {_post, image, _author} = post_with_held_photo!(tmp)
      put_config(:image_pixelation_window_seconds, 0)

      assert Posts.image_pixelated_url(image) == nil
    end
  end

  describe "the post card" do
    test "shows a stranger the pixelated preview tile, never the picture", %{conn: conn, tmp: tmp} do
      {post, image, _author} = post_with_held_photo!(tmp)

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ "data-image-pixelated"
      assert html =~ "/post_images/#{image.token}/pixelated.avif"
      refute html =~ "/post_images/#{image.token}/feed.avif"
    end
  end
end
