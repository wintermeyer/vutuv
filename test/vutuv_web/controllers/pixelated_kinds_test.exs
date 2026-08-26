defmodule VutuvWeb.PixelatedKindsTest do
  @moduledoc """
  The pixelated preview (issue #1720) for the two kinds that are not a member's own post
  photo: the automatic **link screenshot**, whose thumb waits in the quarantine
  tree while the pixelated preview stands in the served one, and a **picture cached from
  another network**, which is served through its authorizing proxy either way.

  Not async: flips the global `:moderate_images` (read by
  `Vutuv.Moderation.ImageScans.enabled?/0` and through it by every uploader)
  and `:uploads_dir_prefix`.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.RemoteMedia
  alias Vutuv.Screenshot

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_pixelated_kinds_#{System.unique_integer([:positive])}")

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

  defp capture!(tmp) do
    path = Path.join(tmp, "capture-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(400, 264, color: [30, 90, 160])
    {:ok, _} = Image.write(image, path)
    %Plug.Upload{filename: Path.basename(path), path: path, content_type: "image/png"}
  end

  defp jpeg_bytes do
    {:ok, image} = Image.new(64, 48, color: [10, 20, 30])
    {:ok, bytes} = Image.write(image, :memory, suffix: ".jpg")
    bytes
  end

  describe "a link screenshot in limbo" do
    setup %{tmp: tmp} do
      post = insert(:post)

      ps =
        Repo.insert!(%PostScreenshot{
          post_id: post.id,
          url: "https://example.com/article",
          status: "ready"
        })

      {:ok, stored} = Screenshot.store({capture!(tmp), ps})
      ps = Repo.update!(Ecto.Changeset.change(ps, screenshot: stored, moderation: "pending"))

      {:ok, ps: ps}
    end

    test "keeps its thumb in quarantine and its pixelated preview in the served tree", %{ps: ps} do
      # The capture itself is unreachable by URL — nginx has no location for
      # the quarantine tree — while the pixelated preview sits where the thumb will go.
      assert Screenshot.url({ps.screenshot, ps}, :thumb) == Screenshot.placeholder_url()
      assert pixelated = Screenshot.pixelated_url(ps)
      assert pixelated =~ "/screenshots/#{ps.id}/pixelated-"
      assert pixelated =~ ".avif"
    end

    test "hands the slot back to the real capture on release", %{ps: ps} do
      Screenshot.promote_from_quarantine(ps)
      released = Repo.update!(Ecto.Changeset.change(ps, moderation: "approved"))

      assert Screenshot.pixelated_url(released) == nil
      assert Screenshot.url({released.screenshot, released}, :thumb) =~ "/screenshots/#{ps.id}/"
      # And the file is gone with it, not merely unreferenced.
      assert Path.wildcard(
               Path.join([
                 Application.get_env(:vutuv, :uploads_dir_prefix),
                 "screenshots",
                 ps.id,
                 "pixelated-*"
               ])
             ) ==
               []
    end
  end

  describe "a picture cached from another network" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(Plug.Test.init_test_session(conn, %{}))

      account =
        Repo.insert!(%RemoteAccount{
          actor_uri: "https://social.example/users/them#{System.unique_integer([:positive])}",
          host: "social.example",
          handle: "them",
          inbox_uri: "https://social.example/inbox"
        })

      now = DateTime.utc_now(:second)

      post =
        Repo.insert!(%RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
          content_text: "Mit Bild.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        })

      row =
        Repo.insert!(%RemoteImage{
          remote_post_id: post.id,
          source_uri: "https://social.example/media/#{System.unique_integer([:positive])}.jpg",
          position: 0,
          moderation: "pending"
        })

      {:ok, %{file: file}} = RemoteMedia.store_post_image(jpeg_bytes(), row.id)
      image = Repo.update!(Ecto.Changeset.change(row, file: file))

      {:ok, conn: conn, user: user, image: image}
    end

    test "answers at its pixelated preview's URL and nowhere else", %{conn: conn, image: image} do
      pixelated = get(conn, RemoteMedia.post_image_pixelated_url(image))

      assert pixelated.status == 200
      assert get_resp_header(pixelated, "cache-control") == ["private, no-store"]
      # Somebody else's picture must never be indexed as ours, stand-in included.
      assert get_resp_header(pixelated, "x-robots-tag") == ["noindex, noimageindex"]

      # The picture's own URL stays shut until the gate clears it.
      assert conn |> get(RemoteMedia.post_image_url(image.id, image.file)) |> Map.fetch!(:status) ==
               404
    end

    test "swaps places with the picture on release", %{conn: conn, image: image} do
      url = RemoteMedia.post_image_pixelated_url(image)

      scan =
        Repo.insert!(%ImageScan{
          kind: "remote_post_image",
          subject_id: image.id,
          fingerprint: image.file,
          status: "scanning"
        })

      assert :ok = ImageSubjects.apply_approved(scan)

      assert conn |> get(RemoteMedia.post_image_url(image.id, image.file)) |> Map.fetch!(:status) ==
               200

      # The stand-in is deleted, so its URL stops answering too — and the
      # reader for it stops offering one at all.
      assert RemoteMedia.post_image_pixelated_path(image.id, image.file) == nil
      assert RemoteMedia.post_image_pixelated_url(image) == nil

      assert conn |> get(url) |> Map.fetch!(:status) == 404
    end
  end
end
