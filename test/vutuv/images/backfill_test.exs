defmodule Vutuv.Images.BackfillTest do
  @moduledoc """
  The contract half of the shared `images` table (issue #2014): every picture
  that existed before the table arrives in it, nothing on disk moves, and the
  check that gates the later column drop is loud about anything it cannot fix.

  Not async: `check/1` reads the disk, so the module holds the global
  `:uploads_dir_prefix` down for its lifetime (`Vutuv.Uploads.disk_dir/1` and
  every uploader read it).
  """
  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Images.Backfill
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Repo

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
        %ImageRow{}
        |> ImageRow.changeset(%{
          kind: "avatar",
          user_id: user.id,
          token: "token-of-the-lost-upload",
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
end
