defmodule Vutuv.Images.BackfillTest do
  @moduledoc """
  The contract half of the shared `images` table (issue #2014): every picture
  that existed before the table arrives in it, nothing on disk moves, and the
  check that gates the later column drop is loud about anything it cannot fix.

  Not async: `check/1` reads the disk, so the module holds the global
  `:uploads_dir_prefix` down for its lifetime (`Vutuv.Uploads.disk_dir/1` and
  every uploader read it), and the operator-output tests below un-silence the
  equally global `:regenerator_quiet` that the three uploads mix tasks read.
  """
  use Vutuv.DataCase, async: false

  import ExUnit.CaptureIO
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Images.Backfill
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Repo
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Spec

  @kind "job_posting_image"
  @post_kind "post_image"

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_backfill_test_#{System.unique_integer([:positive])}")

    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    :ok
  end

  # A picture from before the table: the member row's four columns filled, no
  # row, no pointer — exactly what 1,679 avatars on vutuv.de look like.
  defp legacy_avatar(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          avatar: "old.jpg",
          avatar_fingerprint: "1a2b3c4d5e6f",
          avatar_crop: nil,
          avatar_moderation: "approved"
        },
        attrs
      )

    insert(:activated_user) |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp reload(user), do: Repo.get!(User, user.id)

  # A job-posting picture from before the mirror existed: its own row and its
  # files on disk, nothing in `images`. The factory writes no files, so the
  # served thumb the check probes for is written here.
  defp stored_job_posting_image(attrs \\ []) do
    picture = insert(:job_posting_image, attrs)
    dir = Uploads.disk_dir(Path.join("job_posting_images", picture.token))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "thumb#{Spec.served_ext()}"), "not really an avif")
    picture
  end

  defp job_posting_row(picture), do: Vutuv.ImageHelpers.mirror_row(@kind, picture)

  # The same for a post photo (#2052), which is the same shape carrying far
  # more columns — a caption, a crop, the camera facts and three switches.
  defp stored_post_image(attrs \\ []) do
    picture = insert(:post_image, attrs)
    dir = Uploads.disk_dir(Path.join("post_images", picture.token))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "thumb#{Spec.served_ext()}"), "not really an avif")
    picture
  end

  defp post_image_row(picture), do: Vutuv.ImageHelpers.mirror_row(@post_kind, picture)

  defp jpeg_upload(name \\ "selfie.jpg") do
    src = Path.join(System.tmp_dir!(), "backfill_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: name, path: src, content_type: "image/jpeg"}
  end

  describe "creating the rows that were never written" do
    test "an old avatar arrives with its four values, a token and a pointer" do
      user = legacy_avatar(%{avatar_crop: "0.0000,0.0000,0.5000,0.5000"})

      assert %{"avatar" => tally} = Backfill.run(only: "avatar")
      assert tally.pictures == 1
      assert tally.created == 1
      assert tally.corrected == 0

      image = Images.profile_image(user.id, "avatar")
      assert image.kind == "avatar"
      assert image.file == "old.jpg"
      assert image.fingerprint == "1a2b3c4d5e6f"
      assert image.crop == "0.0000,0.0000,0.5000,0.5000"
      assert image.moderation == "approved"
      assert is_binary(image.token) and image.token != ""
      assert image.frozen_at == nil
      assert reload(user).avatar_image_id == image.id
    end

    test "a picture still on the pre-fingerprint scheme keeps its nil fingerprint" do
      user = legacy_avatar(%{avatar_fingerprint: nil, avatar_moderation: nil})

      Backfill.run(only: "avatar")

      image = Images.profile_image(user.id, "avatar")
      assert image.fingerprint == nil
      assert image.moderation == nil
      assert image.file == "old.jpg"
    end

    test "a member with no picture gets no row" do
      user = insert(:activated_user)

      assert %{"avatar" => %{pictures: 0, created: 0}} = Backfill.run(only: "avatar")
      assert Images.profile_image(user.id, "avatar") == nil
    end

    test "running it again changes nothing" do
      legacy_avatar()

      Backfill.run(only: "avatar")
      assert %{"avatar" => tally} = Backfill.run(only: "avatar")

      assert tally == %{
               pictures: 1,
               created: 0,
               corrected: 0,
               unchanged: 1,
               dropped: 0,
               failed: 0
             }

      assert Repo.aggregate(ImageRow, :count) == 1
    end

    test "a dry run reports without writing" do
      user = legacy_avatar()

      assert %{"avatar" => %{created: 1}} = Backfill.run(only: "avatar", dry_run: true)
      assert Images.profile_image(user.id, "avatar") == nil
    end
  end

  describe "reconciling a row that disagrees" do
    # The shape a half-committed upload left behind before
    # `Accounts.store_pending_image/6` became one transaction: the image row
    # names the new picture, the member row still names the old one. An
    # insert-where-missing backfill skips this member entirely, and the contract
    # deploy then drops the only record of which file is really current.
    test "the member's own columns win, and a changed picture gets a fresh token" do
      user = legacy_avatar()

      {:ok, stale} =
        %ImageRow{kind: "avatar", user_id: user.id, token: "token-of-the-lost-upload"}
        |> ImageRow.changeset(%{
          file: "never-landed.jpg",
          fingerprint: "ffffffffffff",
          moderation: "pending"
        })
        |> Repo.insert()

      assert %{"avatar" => tally} = Backfill.run(only: "avatar")
      assert tally.created == 0
      assert tally.corrected == 1

      image = Images.profile_image(user.id, "avatar")
      assert image.id == stale.id
      assert image.file == "old.jpg"
      assert image.fingerprint == "1a2b3c4d5e6f"
      assert image.moderation == "approved"
      assert image.token != "token-of-the-lost-upload"
      assert reload(user).avatar_image_id == image.id
    end

    test "a row that only lost its pointer keeps its token" do
      user = legacy_avatar()
      Backfill.run(only: "avatar")
      image = Images.profile_image(user.id, "avatar")

      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [avatar_image_id: nil])

      assert %{"avatar" => %{corrected: 1, created: 0}} = Backfill.run(only: "avatar")
      assert reload(user).avatar_image_id == image.id
      assert Images.profile_image(user.id, "avatar").token == image.token
    end

    test "a row whose member has no picture any more is dropped" do
      user = legacy_avatar()
      Backfill.run(only: "avatar")

      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [avatar: nil])

      assert %{"avatar" => %{dropped: 1}} = Backfill.run(only: "avatar")
      assert Images.profile_image(user.id, "avatar") == nil
      assert reload(user).avatar_image_id == nil
    end
  end

  describe "interrupted halfway" do
    # A deploy stops the slot mid-run and logs nothing. The proof is not that
    # the first pass finished — it is that the second one finishes exactly the
    # rest and touches nothing it already did.
    test "a second run finishes the rest and leaves the first half alone" do
      [first, second] = Enum.sort_by([legacy_avatar(), legacy_avatar()], & &1.id)

      # Kill it after the first member: resuming from that id is what the run's
      # own progress line tells the operator to do.
      assert %{"avatar" => %{created: 1}} = Backfill.run(only: "avatar", from: first.id)
      assert Images.profile_image(first.id, "avatar") == nil
      assert Images.profile_image(second.id, "avatar")

      assert %{"avatar" => tally} = Backfill.run(only: "avatar")
      assert tally.created == 1
      assert tally.unchanged == 1
      assert tally.corrected == 0

      assert Images.profile_image(first.id, "avatar")
      assert Repo.aggregate(ImageRow, :count) == 2
    end
  end

  describe "both kinds" do
    test "avatars and covers are counted apart" do
      user =
        legacy_avatar()
        |> Ecto.Changeset.change(%{
          cover_photo: "banner.jpg",
          cover_fingerprint: "aabbccddeeff",
          cover_moderation: "approved"
        })
        |> Repo.update!()

      assert %{"avatar" => avatars, "cover" => covers} = Backfill.run()
      assert avatars.created == 1
      assert covers.created == 1

      assert Images.profile_image(user.id, "avatar").file == "old.jpg"
      assert Images.profile_image(user.id, "cover").file == "banner.jpg"
      assert reload(user).cover_image_id == Images.profile_image(user.id, "cover").id
    end
  end

  describe "a gallery kind: the job-posting picture (issue #2054)" do
    test "one that predates the mirror arrives with every column" do
      picture = stored_job_posting_image()

      assert %{"job_posting_image" => tally} = Backfill.run(only: @kind)
      assert tally.pictures == 1
      assert tally.created == 1

      assert %ImageRow{} = row = job_posting_row(picture)
      assert row.kind == @kind
      assert row.user_id == picture.user_id
      assert row.alt == picture.alt
      assert row.width == picture.width
      assert row.height == picture.height
      assert row.content_type == picture.content_type
      assert row.size_bytes == picture.size_bytes
      assert row.moderation == picture.moderation
    end

    test "running it again changes nothing" do
      stored_job_posting_image()
      Backfill.run(only: @kind)

      assert %{"job_posting_image" => tally} = Backfill.run(only: @kind)
      assert tally.unchanged == 1
      assert tally.created == 0
      assert tally.corrected == 0
    end

    test "a row that drifted is corrected, and keeps its token" do
      picture = stored_job_posting_image()
      Backfill.run(only: @kind)
      before = job_posting_row(picture)

      Repo.update_all(from(i in ImageRow, where: i.id == ^before.id),
        set: [alt: "stale", moderation: "pending"]
      )

      assert %{"job_posting_image" => tally} = Backfill.run(only: @kind)
      assert tally.corrected == 1
      assert tally.created == 0

      after_run = job_posting_row(picture)
      assert after_run.id == before.id
      assert after_run.token == before.token
      assert after_run.alt == picture.alt
      assert after_run.moderation == picture.moderation
    end

    test "a row whose picture is gone is dropped" do
      picture = stored_job_posting_image()
      Backfill.run(only: @kind)
      Repo.delete_all(from(i in JobPostingImage, where: i.id == ^picture.id))

      assert %{"job_posting_image" => tally} = Backfill.run(only: @kind)
      assert tally.dropped == 1
      refute job_posting_row(picture)
    end

    # The proof is not that the first pass finished — it is that the second one
    # finishes exactly the rest and touches nothing it already did.
    test "a second run after an interruption finishes exactly the rest" do
      [first, second] =
        Enum.sort_by([stored_job_posting_image(), stored_job_posting_image()], & &1.id)

      assert %{"job_posting_image" => %{created: 1}} =
               Backfill.run(only: @kind, from: first.id)

      refute job_posting_row(first)
      assert job_posting_row(second)

      assert %{"job_posting_image" => tally} = Backfill.run(only: @kind)
      assert tally.created == 1
      assert tally.unchanged == 1
      assert tally.corrected == 0
      assert job_posting_row(first)
      assert Repo.aggregate(from(i in ImageRow, where: i.kind == ^@kind), :count) == 2
    end

    test "the check names the pictures with no row, and goes quiet once they have one" do
      picture = stored_job_posting_image()

      assert %{kinds: %{"job_posting_image" => before}, ok?: false} =
               Backfill.check(only: @kind)

      assert before.missing_row.count == 1
      assert before.missing_row.sample == [picture.id]
      assert before.missing_file.count == 0

      Backfill.run(only: @kind)

      assert %{ok?: true} = Backfill.check(only: @kind)
    end

    test "a picture whose file is gone is named and never repaired away" do
      picture = stored_job_posting_image()
      File.rm_rf!(Vutuv.Uploads.disk_dir(Path.join("job_posting_images", picture.token)))
      Backfill.run(only: @kind)

      assert %{kinds: %{"job_posting_image" => result}, ok?: false} =
               Backfill.check(only: @kind)

      assert result.missing_file.count == 1
      assert result.missing_row.count == 0
      assert job_posting_row(picture)
    end

    test "the report says nothing about a pointer this kind never had" do
      put_config(:regenerator_quiet, false)
      stored_job_posting_image()

      output = capture_io(fn -> Backfill.check(only: @kind) end)

      assert output =~ "job_posting_image: 1 picture(s), 0 row(s)"
      assert output =~ "1 without a row"
      refute output =~ "not pointed at"
    end

    test "the mix task takes the kind by name" do
      put_config(:regenerator_quiet, false)
      picture = stored_job_posting_image()

      capture_io(fn ->
        assert %{ok?: true} =
                 Mix.Tasks.Vutuv.Images.Backfill.run(["--only", "job_posting_image"])
      end)

      assert job_posting_row(picture)
    end
  end

  # The machinery above is the machinery here — a gallery source builds itself
  # from `Vutuv.Images.mirror_source/1`, so the post photo added no line to
  # `Vutuv.Images.Backfill`. What is worth its own tests is the part the second
  # kind could get wrong on its own: the registry entry reaching this pass at
  # all, and the columns no other kind has surviving the copy.
  describe "a gallery kind: the post photo (issue #2052)" do
    test "it is one of the kinds a bare run walks" do
      assert @post_kind in Backfill.kinds()
    end

    test "one that predates the mirror arrives with the columns no other kind has" do
      picture =
        stored_post_image(
          alt: "Ein Feld im Abendlicht",
          caption: "Am letzten Morgen in Lissabon",
          crop: "0.0000,0.0000,0.5000,0.5000",
          camera: "Fujifilm X-T5",
          lens: "XF 35mm F1.4 R",
          focal_length: "35 mm",
          aperture: "f/1.4",
          shutter: "1/250 s",
          iso: 400,
          taken_at: ~N[2026-08-01 06:14:00],
          has_gps: true,
          show_camera_info: true,
          download_original: true
        )

      assert %{@post_kind => tally} = Backfill.run(only: @post_kind)
      assert tally.pictures == 1
      assert tally.created == 1

      assert %ImageRow{} = row = post_image_row(picture)
      assert row.kind == @post_kind
      assert row.user_id == picture.user_id
      assert row.post_id == picture.post_id
      assert row.caption == picture.caption
      assert row.crop == picture.crop
      assert row.camera == picture.camera
      assert row.lens == picture.lens
      assert row.focal_length == picture.focal_length
      assert row.aperture == picture.aperture
      assert row.shutter == picture.shutter
      assert row.iso == picture.iso
      assert row.taken_at == picture.taken_at
      assert row.has_gps == true
      assert row.show_camera_info == true
      assert row.download_original == true
      assert row.download_exact == false
    end

    test "a row whose caption drifted is corrected, and keeps its token" do
      picture = stored_post_image(caption: "Am letzten Morgen in Lissabon")
      Backfill.run(only: @post_kind)
      before = post_image_row(picture)

      Repo.update_all(from(i in ImageRow, where: i.id == ^before.id),
        set: [caption: "stale", has_gps: true]
      )

      assert %{@post_kind => tally} = Backfill.run(only: @post_kind)
      assert tally.corrected == 1

      after_run = post_image_row(picture)
      assert after_run.token == before.token
      assert after_run.caption == picture.caption
      assert after_run.has_gps == false
    end

    test "the check names the photos with no row, and goes quiet once they have one" do
      picture = stored_post_image()

      assert %{kinds: %{@post_kind => before}, ok?: false} = Backfill.check(only: @post_kind)
      assert before.missing_row.count == 1
      assert before.missing_row.sample == [picture.id]
      assert before.missing_file.count == 0

      Backfill.run(only: @post_kind)

      assert %{ok?: true} = Backfill.check(only: @post_kind)
    end
  end

  describe "the check before the cut" do
    test "it names the members with no row, and goes quiet once they have one" do
      user = legacy_avatar()

      %{kinds: %{"avatar" => before}, ok?: ok_before?} = Backfill.check(only: "avatar")
      refute ok_before?
      assert before.pictures == 1
      assert before.rows == 0
      assert before.missing_row == %{count: 1, sample: [user.id]}

      Backfill.run(only: "avatar")

      %{kinds: %{"avatar" => after_run}} = Backfill.check(only: "avatar")
      assert after_run.missing_row.count == 0
      assert after_run.mismatched_row.count == 0
      assert after_run.missing_pointer.count == 0
      assert after_run.orphan_row.count == 0
      assert after_run.rows == 1
    end

    test "it names a row that disagrees with the member row" do
      user = legacy_avatar()
      Backfill.run(only: "avatar")

      Repo.update_all(
        from(i in ImageRow, where: i.user_id == ^user.id),
        set: [file: "something-else.jpg"]
      )

      %{kinds: %{"avatar" => result}, ok?: ok?} = Backfill.check(only: "avatar")
      refute ok?
      assert result.mismatched_row == %{count: 1, sample: [user.id]}
      assert result.missing_row.count == 0
    end

    test "it names an orphan row" do
      user = legacy_avatar()
      Backfill.run(only: "avatar")
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [avatar: nil])

      %{kinds: %{"avatar" => result}, ok?: ok?} = Backfill.check(only: "avatar")
      refute ok?

      assert result.orphan_row == %{
               count: 1,
               sample: [Images.profile_image(user.id, "avatar").id]
             }
    end

    # Calibration: the same check, one member whose bytes are on disk and one
    # whose are not. A file check that cannot tell them apart reads "all clear"
    # for a whole tree that is gone.
    test "it tells a picture whose file is there from one whose file is not" do
      user = insert(:activated_user)
      insert(:email, user: user)
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})
      Backfill.run(only: "avatar")

      %{kinds: %{"avatar" => present}, ok?: ok?} = Backfill.check(only: "avatar")
      assert ok?
      assert present.missing_file.count == 0

      File.rm_rf!(Vutuv.Uploads.disk_dir("avatars/#{user.id}"))

      %{kinds: %{"avatar" => gone}, ok?: still_ok?} = Backfill.check(only: "avatar")
      refute still_ok?
      assert gone.missing_file == %{count: 1, sample: [user.id]}
      # The row is still right — the bytes are what went missing, and the
      # backfill cannot bring those back.
      assert gone.missing_row.count == 0
      assert gone.mismatched_row.count == 0
    end

    test "a picture waiting in quarantine counts its quarantined file" do
      put_config(:moderate_images, true)
      user = insert(:activated_user)
      insert(:email, user: user)
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})

      assert user.avatar_moderation == "pending"
      Backfill.run(only: "avatar")

      %{kinds: %{"avatar" => result}, ok?: ok?} = Backfill.check(only: "avatar")
      assert ok?, "a pending picture lives in the quarantine tree, not the served one"
      assert result.missing_file.count == 0
    end
  end

  # The half that a rehearsal driving `Backfill.run/1` and `check/1` directly
  # never touches, and the half the operator actually meets. The first version
  # of it lived in the mix task, went out of step with what `check/1` returns,
  # and crashed on every single invocation — while the release path printed
  # nothing at all and exited 0 with 1,678 mismatches outstanding.
  describe "what the operator sees" do
    setup do
      put_config(:regenerator_quiet, false)
      :ok
    end

    test "the check names what is wrong, with the member behind it" do
      user = legacy_avatar()

      output = capture_io(fn -> assert %{ok?: false} = Backfill.check(only: "avatar") end)

      assert output =~ "avatar: 1 picture(s), 0 row(s)"
      assert output =~ "1 without a row"
      assert output =~ "without a row: #{user.id}"
      assert output =~ "MISMATCH"
      refute output =~ "Safe to cut"
    end

    test "and says it is safe to cut once everything is in order" do
      user = insert(:activated_user)
      insert(:email, user: user)
      {:ok, _user} = Accounts.update_user(user, %{avatar: jpeg_upload()})
      capture_io(fn -> Backfill.run(only: "avatar") end)

      output = capture_io(fn -> assert %{ok?: true} = Backfill.check(only: "avatar") end)

      assert output =~ "avatar: 1 picture(s), 1 row(s)"
      assert output =~ "0 without a row"
      assert output =~ "0 with no file on disk"
      assert output =~ "Safe to cut"
      refute output =~ "MISMATCH"
    end

    test "a long list of ids is capped and says how many there really are" do
      for _ <- 1..12, do: legacy_avatar()

      output = capture_io(fn -> Backfill.check(only: "avatar") end)

      assert output =~ "12 without a row"
      assert output =~ "… (12 total)"

      assert length(String.split(Regex.run(~r/without a row: (.+) …/, output) |> Enum.at(1))) ==
               10
    end

    test "the mix task reconciles and succeeds when everything is in order" do
      user = insert(:activated_user)
      insert(:email, user: user)
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})
      Repo.delete_all(from(i in ImageRow, where: i.user_id == ^user.id))

      capture_io(fn ->
        assert %{ok?: true} = Mix.Tasks.Vutuv.Images.Backfill.run([])
      end)

      assert Images.profile_image(user.id, "avatar")
    end

    test "the mix task fails the command when something is outstanding" do
      legacy_avatar()

      capture_io(fn ->
        assert_raise Mix.Error, ~r/check failed/, fn ->
          Mix.Tasks.Vutuv.Images.Backfill.run(["--check"])
        end
      end)
    end
  end
end
