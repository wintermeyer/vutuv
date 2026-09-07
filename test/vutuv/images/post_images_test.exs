defmodule Vutuv.Images.PostImagesTest do
  @moduledoc """
  The largest of the four kinds #2015 moves into the shared `images` table
  (issue #2052): a post photo is a row there beside its own row, kept in step
  by every write, and nothing about how it is stored or served has moved.

  The shape is #2054's — the join is the `token` both rows carry, the mirror is
  one upsert and one delete, and the registry in `Vutuv.Images` is what the
  backfill reads. What is new here is how much a photo carries: a caption, a
  crop, seven camera facts, a GPS flag and the author's three switches, all of
  which have to survive the deploy that retires `post_images`.

  Not async: the upload path writes files, so the module holds the global
  `:uploads_dir_prefix` down for its lifetime.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.ImageHelpers
  alias Vutuv.Images
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo

  @kind "post_image"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_post_images_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp, user: insert(:activated_user)}
  end

  defp upload!(user, tmp) do
    src = Path.join(tmp, "src-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(640, 480, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)
    {:ok, image} = Posts.create_pending_image(user, src, "photo.jpg")
    image
  end

  defp mirror(picture), do: ImageHelpers.mirror_row(@kind, picture)

  describe "the row beside the row" do
    # Field by field off the registry rather than off a list written a second
    # time here, so a field added to `@mirrored` and forgotten on the request
    # path fails this without anybody editing the test. The three assertions
    # outside the loop are what the mirror sets rather than copies.
    test "an upload writes one, column for column", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)

      assert %ImageRow{} = row = mirror(image)
      assert row.kind == @kind
      assert row.id != image.id
      assert row.frozen_at == nil

      for field <- Images.mirror_source(@kind).fields do
        assert Map.fetch!(row, field) == Map.fetch!(image, field),
               "#{field} drifted: #{inspect(Map.fetch!(row, field))} != " <>
                 inspect(Map.fetch!(image, field))
      end
    end

    test "attaching the photo to a post moves the parent and the position across", %{
      tmp: tmp,
      user: user
    } do
      first = upload!(user, tmp)
      second = upload!(user, tmp)

      {:ok, post} =
        Posts.create_post(user, %{body: "Zwei Fotos.", image_ids: [first.id, second.id]})

      assert mirror(first).post_id == post.id
      assert mirror(first).position == 0
      assert mirror(second).post_id == post.id
      assert mirror(second).position == 1
    end

    test "an edited alt text follows", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)

      {:ok, _} = Posts.update_image_alt(image, "Blick über die Elbe")

      assert mirror(image).alt == "Blick über die Elbe"
    end

    test "the composer's per-photo panel follows: caption and the two switches", %{
      tmp: tmp,
      user: user
    } do
      image = upload!(user, tmp)

      {:ok, _} =
        Posts.update_image_settings(image, %{
          "alt" => "Ein Feld im Abendlicht",
          "caption" => "Am letzten Morgen in Lissabon",
          "show_camera_info" => "true",
          "download_original" => "true",
          "download_exact" => "true"
        })

      row = mirror(image)
      assert row.caption == "Am letzten Morgen in Lissabon"
      assert row.show_camera_info == true
      assert row.download_original == true
      assert row.download_exact == true
    end

    # A crop is the one edit that changes what the served frame *is*: the
    # fractions, the dimensions they produce and the exact-file download that
    # has to go with them all move together.
    test "a crop follows, dimensions and exact-file flag included", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      {:ok, _} = Posts.update_image_settings(image, %{"download_original" => "true"})

      {:ok, cropped} = Posts.crop_image(Repo.reload!(image), "0,0,0.5,0.5")

      row = mirror(image)
      assert row.crop == cropped.crop
      assert row.width == cropped.width
      assert row.height == cropped.height
      assert row.download_exact == false
    end

    # The camera facts are parsed at upload and never cast from params, so this
    # writes them the way `Vutuv.Uploads.Exif` would and then makes an ordinary
    # edit — which is the moment the mirror has to carry them.
    test "the camera facts and the GPS flag ride along", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)

      {:ok, image} =
        image
        |> Ecto.Changeset.change(%{
          camera: "Fujifilm X-T5",
          lens: "XF 35mm F1.4 R",
          focal_length: "35 mm",
          aperture: "f/1.4",
          shutter: "1/250 s",
          iso: 400,
          taken_at: ~N[2026-08-01 06:14:00],
          has_gps: true
        })
        |> Repo.update()

      {:ok, _} = Posts.update_image_alt(image, "Sonnenaufgang")

      row = mirror(image)
      assert row.camera == "Fujifilm X-T5"
      assert row.lens == "XF 35mm F1.4 R"
      assert row.focal_length == "35 mm"
      assert row.aperture == "f/1.4"
      assert row.shutter == "1/250 s"
      assert row.iso == 400
      assert row.taken_at == ~N[2026-08-01 06:14:00]
      assert row.has_gps == true
    end

    test "the AI gate's release follows", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)

      Repo.update_all(from(i in PostImage, where: i.id == ^image.id),
        set: [moderation: "pending"]
      )

      Repo.update_all(from(i in ImageRow, where: i.token == ^image.token),
        set: [moderation: "pending"]
      )

      scan = insert(:image_scan, kind: @kind, subject_id: image.id, owner_user_id: user.id)
      assert :ok = ImageSubjects.apply_approved(scan)

      assert mirror(image).moderation == "approved"
    end
  end

  describe "the row goes when the picture goes" do
    test "a pending upload the member discards", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      assert mirror(image)

      :ok = Posts.delete_pending_image(image)

      refute mirror(image)
    end

    test "a photo the author removed while editing the post", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      {:ok, post} = Posts.create_post(user, %{body: "Mit Foto.", image_ids: [image.id]})
      assert mirror(image)

      {:ok, _} = Posts.update_post(post, %{body: "Ohne Foto.", image_ids: []})

      refute Repo.get(PostImage, image.id)
      refute mirror(image)
    end

    test "a pending upload nobody ever attached", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      assert mirror(image)
      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -25 * 3600, :second)

      Repo.update_all(from(i in PostImage, where: i.id == ^image.id), set: [inserted_at: old])

      assert Posts.sweep_pending_images() == 1

      refute mirror(image)
    end

    test "a post that is deleted", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      {:ok, post} = Posts.create_post(user, %{body: "Mit Foto.", image_ids: [image.id]})
      assert mirror(image)

      {:ok, _} = Posts.delete_post(post)

      refute mirror(image)
    end

    test "a photo the AI gate rejected", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      assert mirror(image)
      scan = insert(:image_scan, kind: @kind, subject_id: image.id, owner_user_id: user.id)

      assert :ok = ImageSubjects.apply_rejected(scan)

      refute Repo.get(PostImage, image.id)
      refute mirror(image)
    end

    # No call anywhere does this: `images.user_id` carries the same
    # `on_delete: :delete_all` the photo's own row does.
    test "a member who deletes their account", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      assert mirror(image)

      {:ok, _} = Accounts.delete_user(user)

      refute Repo.get(PostImage, image.id)
      refute mirror(image)
    end
  end

  describe "the mirror carries the whole picture" do
    # That every column is copied, or excluded on purpose, is asserted for
    # every mirrored kind at once in `Vutuv.ImagesTest`. This is the one column
    # of the thirteen whose *type* the copy can get wrong: `caption` is `text`
    # on `post_images` because a photographer's note runs long (1,000
    # characters through the composer), and a varchar(255) copy would raise
    # Postgres 22001 on the mirror — on the *write* path, where no changeset
    # validation stands between the member and the error.
    test "a caption at its full length survives the copy", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      long = String.duplicate("ä", PostImage.max_caption_length())

      {:ok, _} = Posts.update_image_settings(image, %{"caption" => long})

      assert mirror(image).caption == long
    end
  end

  describe "nothing about serving moved" do
    test "the URL is the one it always was", %{tmp: tmp, user: user} do
      image = upload!(user, tmp)
      assert mirror(image)

      assert PostImage.url(image, "feed") == "/post_images/#{image.token}/feed.avif"
    end

    # The report form addresses a picture by its `images` row id, and until this
    # release no row of this kind existed — so nothing could name one. Now one
    # does, and `Vutuv.Images.freeze/1` has no clause for it: the takedown is
    # the next release's work. A report has to be refused rather than accepted
    # into a case whose uphold would raise (issue #2057).
    test "a copyright report cannot name one yet — the freeze has no path for it", %{
      tmp: tmp,
      user: user
    } do
      row = mirror(upload!(user, tmp))
      reporter = insert(:activated_user)

      refute Vutuv.Moderation.can_report?(reporter, row)

      assert {:error, :not_allowed} =
               Vutuv.Moderation.report_content(reporter, row, %{
                 "category" => "copyright",
                 "details" => "That is my photograph."
               })
    end

    # That `freeze/1`, `unfreeze/1` and `purge/1` raise for every kind the gate
    # refuses is asserted over `Images.kinds()` in
    # `Vutuv.ModerationImageTakedownTest`, so adding this kind there covered it.
  end
end
