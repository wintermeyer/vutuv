defmodule Vutuv.ModerationImageTakedownTest do
  @moduledoc """
  A profile picture is reportable in its own right (issue #2012).

  The whole point of the type is that a freeze **moves** bytes instead of
  deleting them: every derived version and the private original leave the trees
  a reader can reach for a hold nginx has no location for, the profile falls
  back to the silhouette, a rejected case puts every file back byte for byte at
  the same path, and only an upheld case deletes anything.

  So the assertions here are mostly about the disk: a fingerprint of the whole
  upload tree taken before the report has to come back identical after the
  reject.
  """

  # Not async: flips the global :uploads_dir_prefix.
  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Images.Backfill
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Moderation
  alias Vutuv.Moderation.Report
  alias Vutuv.PressKit
  alias Vutuv.Repo

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_image_takedown_#{System.unique_integer([:positive])}")

    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    owner = insert(:activated_user)
    insert(:email, user: owner)
    reporter = insert(:activated_user)
    insert(:email, user: reporter)
    admin = insert(:activated_user, admin?: true)
    insert(:email, user: admin)

    {:ok, owner} = Accounts.update_user(owner, %{avatar: jpeg_upload()})

    {:ok, tmp: tmp, owner: owner, reporter: reporter, admin: admin}
  end

  defp jpeg_upload(name \\ "selfie.jpg", color \\ [10, 120, 200]) do
    src = Path.join(System.tmp_dir!(), "takedown_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: color)
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: name, path: src, content_type: "image/jpeg"}
  end

  defp reload(user), do: Repo.get!(User, user.id)

  defp reload_row(%ImageRow{id: id}), do: Repo.get(ImageRow, id)

  # A press picture (issue #2084): the third kind the gate admits, and the one
  # whose files are keyed by the row's own token rather than by a member scope.
  # `PressKit.create/4` takes the `{path, filename}` pair the socket upload hands
  # over, so the shared fixture's `%Plug.Upload{}` is unwrapped rather than
  # rebuilt.
  defp press_picture(owner) do
    %Plug.Upload{path: src} = jpeg_upload("press.jpg", [40, 90, 30])

    {:ok, image} =
      PressKit.create(owner, owner, {src, "press.jpg"}, %{"rights_confirmed" => "true"})

    image
  end

  defp notice(attrs \\ %{}) do
    Map.merge(
      %{
        "category" => "copyright",
        "note" => "That is my photograph, the original is at example.com/photo",
        "good_faith?" => "true"
      },
      attrs
    )
  end

  # Every file under the uploads root, as `relative path => sha256`. The whole
  # round trip is one comparison of two of these: same paths, same bytes.
  defp tree(root) do
    root
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Map.new(fn path ->
      {Path.relative_to(path, root), :crypto.hash(:sha256, File.read!(path))}
    end)
  end

  defp served_files(root, user), do: Path.wildcard(Path.join([root, "avatars", user.id, "*"]))

  defp originals(root, user),
    do: Path.wildcard(Path.join([root, "originals/avatars", user.id, "*"]))

  defp held_files(root, image), do: Path.wildcard(Path.join([root, "frozen", image.id, "**"]))

  defp avatar_image(user), do: Images.profile_image(user.id, "avatar")

  # A member whose avatar predates the fingerprinted file name: the row names
  # the upload, the files on disk carry the stable legacy name
  # (`avatar_<version>.avif`) and no fingerprint column is set. The backfill is
  # what gives it its `images` row, exactly as it did in production.
  defp legacy_avatar_owner(root) do
    user = insert(:activated_user, avatar: "Image703.jpg?63659747708", avatar_fingerprint: nil)
    insert(:email, user: user)

    dir = Path.join([root, "avatars", user.id])
    File.mkdir_p!(dir)

    for version <- ~w(thumb medium large),
        do: File.write!(Path.join(dir, "avatar_#{version}.avif"), "legacy #{version} bytes")

    File.mkdir_p!(Path.join([root, "originals/avatars", user.id]))

    File.write!(
      Path.join([root, "originals/avatars", user.id, "original.jpg"]),
      "legacy original"
    )

    Backfill.run(only: "avatar")
    user
  end

  # Whether one of the emails delivered so far went to this member.
  defp assert_mailed(%User{} = user) do
    address = Accounts.first_email_value(user)
    recipients = Enum.flat_map(flush_emails(), fn email -> Enum.map(email.to, &elem(&1, 1)) end)

    assert address in recipients,
           "no email to #{address}; got #{inspect(recipients)}"
  end

  describe "reporting a profile picture" do
    test "the freeze moves every file into the hold and the reject brings them all back",
         %{tmp: tmp, owner: owner, reporter: reporter, admin: admin} do
      image = avatar_image(owner)
      before = tree(tmp)
      url_before = Vutuv.Avatar.display_url(owner, :medium)

      assert served_files(tmp, owner) != []
      assert originals(tmp, owner) != []

      {:ok, case_record} = Moderation.report_content(reporter, image, notice())

      assert case_record.content_type == "image"
      assert case_record.content_id == image.id
      assert case_record.owner_id == owner.id

      # Nothing is deleted: the bytes are all still there, just out of reach.
      assert Repo.get!(ImageRow, image.id).frozen_at
      assert served_files(tmp, owner) == []
      assert originals(tmp, owner) == []
      assert length(held_files(tmp, image) |> Enum.reject(&File.dir?/1)) == map_size(before)

      # And the profile shows the silhouette meanwhile.
      frozen_owner = reload(owner)
      assert frozen_owner.avatar == nil
      assert frozen_owner.avatar_fingerprint == nil
      assert String.starts_with?(Vutuv.Avatar.display_url(frozen_owner, :medium), "data:image/")

      {:ok, _} = Moderation.reject_case(case_record, admin)

      # Byte for byte, at the same paths, so the old URL works again.
      assert tree(tmp) == before
      assert Repo.get!(ImageRow, image.id).frozen_at == nil

      restored = reload(owner)
      assert restored.avatar == "selfie.jpg"
      assert restored.avatar_fingerprint == owner.avatar_fingerprint
      assert Vutuv.Avatar.display_url(restored, :medium) == url_before
    end

    test "an upheld case deletes the copies, the original included",
         %{tmp: tmp, owner: owner, reporter: reporter, admin: admin} do
      image = avatar_image(owner)
      {:ok, case_record} = Moderation.report_content(reporter, image, notice())

      {:ok, _} = Moderation.uphold_case(case_record, admin)

      assert tree(tmp) == %{}
      assert avatar_image(owner) == nil
      assert reload(owner).avatar == nil
    end

    test "the owner's self-service is remove, and it settles the case",
         %{tmp: tmp, owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, case_record} = Moderation.report_content(reporter, image, notice())

      assert :ok = Moderation.delete_reported_content(case_record, owner)

      assert tree(tmp) == %{}
      assert avatar_image(owner) == nil
      assert Repo.get!(Moderation.Case, case_record.id).status == "resolved_deleted"
    end

    test "a frozen picture cannot be replaced by a fresh upload",
         %{owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, _case} = Moderation.report_content(reporter, image, notice())

      {:ok, unchanged} = Accounts.update_user(reload(owner), %{avatar: jpeg_upload("other.jpg")})

      # The freeze survives the re-upload, and so does the frozen picture's row:
      # replacing it would move the case onto bytes nobody reported.
      assert unchanged.avatar == nil
      row = Repo.get!(ImageRow, image.id)
      assert row.frozen_at
      assert row.file == "selfie.jpg"
      assert row.token == image.token
    end

    test "an interrupted freeze is finished by the reconcile pass",
         %{tmp: tmp, owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, _case} = Moderation.report_content(reporter, image, notice())

      # A deploy killed the slot between the two halves of the move: the stamp
      # is written, some bytes are still in the served tree.
      stray = Path.join([tmp, "avatars", owner.id, "leftover-medium-deadbeef.avif"])
      File.mkdir_p!(Path.dirname(stray))
      File.write!(stray, "left behind")

      assert :ok = Images.reconcile_holds()

      assert served_files(tmp, owner) == []

      assert Path.join([tmp, "frozen", image.id, "served", "leftover-medium-deadbeef.avif"])
             |> File.exists?()
    end
  end

  describe "which report takes a picture offline (issue #2030)" do
    # The freeze is calibrated to the category, not to the reporter's standing.
    # `trusted_reporter?/1` says yes to an account created a minute ago —
    # nothing of theirs has been rejected yet — so before this split one
    # throwaway account took any member's avatar off every surface with its
    # first ever report.
    test "a house-rule report leaves the picture where it is and puts the case in the queue",
         %{tmp: tmp, owner: owner, reporter: reporter, admin: admin} do
      image = avatar_image(owner)
      before = tree(tmp)

      {:ok, case_record} =
        Moderation.report_content(reporter, image, %{"category" => "bullying"})

      assert case_record.status == "flagged"
      assert Repo.get!(ImageRow, image.id).frozen_at == nil

      # Not one byte moved, and the profile still shows the picture.
      assert tree(tmp) == before
      assert held_files(tmp, image) == []
      assert reload(owner).avatar == "selfie.jpg"

      # An admin has it in front of them all the same.
      assert case_record.id in Enum.map(Moderation.list_queue(), & &1.id)
      assert_mailed(admin)
    end

    test "a second house-rule report does not hide it either",
         %{tmp: tmp, owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      other = insert(:activated_user)

      {:ok, _first} = Moderation.report_content(reporter, image, %{"category" => "family"})
      {:ok, second} = Moderation.report_content(other, image, %{"category" => "bullying"})

      assert second.status == "flagged"
      assert Repo.get!(ImageRow, image.id).frozen_at == nil
      assert served_files(tmp, owner) != []
    end

    test "a copyright notice still takes it offline on the spot",
         %{tmp: tmp, owner: owner, reporter: reporter} do
      image = avatar_image(owner)

      {:ok, case_record} = Moderation.report_content(reporter, image, notice())

      assert case_record.status == "pending_owner"
      assert Repo.get!(ImageRow, image.id).frozen_at
      assert served_files(tmp, owner) == []
    end

    # A copyright notice joining a case a house-rule report opened is still a
    # legal notice, so it freezes the picture the moment it arrives.
    test "a copyright notice on an already-flagged case freezes it",
         %{tmp: tmp, owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      rights_holder = insert(:activated_user)

      {:ok, _flagged} = Moderation.report_content(reporter, image, %{"category" => "other"})
      {:ok, upgraded} = Moderation.report_content(rights_holder, image, notice())

      assert upgraded.status == "pending_owner"
      assert Repo.get!(ImageRow, image.id).frozen_at
      assert served_files(tmp, owner) == []
    end

    # The refusal is about the hold, not about the case: nothing was moved, so
    # there is nothing a replacement could strand.
    test "the owner can replace a picture that was only flagged",
         %{owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, case_record} = Moderation.report_content(reporter, image, %{"category" => "family"})

      # A different colour, not just a different name: `jpeg_upload/2` encodes
      # deterministically, so a rename alone is the byte-identical re-upload of
      # the test below.
      {:ok, replaced} =
        Accounts.update_user(reload(owner), %{avatar: jpeg_upload("other.jpg", [220, 60, 30])})

      assert replaced.avatar == "other.jpg"
      assert Repo.get!(ImageRow, image.id).file == "other.jpg"
      assert replaced.avatar_fingerprint != owner.avatar_fingerprint

      # And the case is settled with them: the reported bytes are gone, so
      # leaving it open would point an admin's ruling at a picture nobody
      # reported. As a **revision**, not a deletion (issue #2067): the row keeps
      # its id and a picture the reporter can still see stands in its place, so
      # closing it as `resolved_deleted` put "was deleted" in their notice's
      # subject and "still visible" in its body.
      assert Repo.get!(Moderation.Case, case_record.id).status == "resolved_edited"
    end

    # Issue #2035: the settle above is earned by the bytes changing, not by an
    # upload happening. Putting the very same file back replaced nothing, so it
    # must not close the report — that was a way to make a complaint disappear
    # without an admin ever seeing it, and it cost the owner nothing.
    test "re-uploading the identical picture does not settle the case",
         %{owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, case_record} = Moderation.report_content(reporter, image, %{"category" => "family"})
      queue_before = Moderation.open_queue_count()

      {:ok, same} = Accounts.update_user(reload(owner), %{avatar: jpeg_upload()})

      # Same file in, same fingerprint out: the row still names the bytes the
      # report is about.
      assert same.avatar_fingerprint == owner.avatar_fingerprint
      assert Repo.get!(ImageRow, image.id).fingerprint == owner.avatar_fingerprint

      assert Repo.get!(Moderation.Case, case_record.id).status == "flagged"
      assert Moderation.open_queue_count() == queue_before
    end

    # The crop is folded into the fingerprint, so a re-crop of the same original
    # is a different served picture — and everybody who follows the report's
    # link now sees different bytes.
    test "re-cropping the same original counts as a replacement",
         %{owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, case_record} = Moderation.report_content(reporter, image, %{"category" => "family"})

      {:ok, cropped} =
        Accounts.update_user(reload(owner), %{
          "avatar" => jpeg_upload(),
          "avatar_crop" => "0.25,0,0.5,1"
        })

      assert cropped.avatar_fingerprint != owner.avatar_fingerprint
      assert Repo.get!(Moderation.Case, case_record.id).status == "resolved_edited"
    end
  end

  # `Images.takedown_ready?/1` decides whether a report may name a picture, and
  # the freeze is what accepting one eventually runs — so a kind the gate admits
  # and the freeze cannot act on is an error page in front of the admin who
  # upholds the case. Both tests split `Images.kinds()` by the gate rather than
  # naming today's three, so a kind that joins the table has to answer for
  # itself (issue #2057).
  describe "the gate and the takedown answer one question (issue #2057)" do
    setup %{owner: owner} do
      {:ok, owner} = Accounts.update_user(owner, %{cover_photo: jpeg_upload("wide.jpg")})

      {ready, refused} =
        Enum.split_with(Images.kinds(), &Images.takedown_ready?(%ImageRow{kind: &1}))

      {:ok, owner: owner, ready: ready, refused: refused}
    end

    test "every kind it admits really freezes, unfreezes and purges",
         %{owner: owner, ready: ready} do
      # Real pictures, because "the takedown can act on it" is a claim about
      # files moving, not about a clause existing.
      real =
        ~w(avatar cover)
        |> Map.new(&{&1, Images.profile_image(owner.id, &1)})
        |> Map.put("press_kit", press_picture(owner))

      for kind <- ready do
        row = Map.get(real, kind)

        assert row,
               "#{kind} is takedown-ready but nothing here takes one offline. Either " <>
                 "it has no strategy in Vutuv.Images' @takedown, and then the gate " <>
                 "must not admit it, or it has one and this test needs a real " <>
                 "picture of that kind."

        assert :ok = Images.freeze(row)
        assert reload_row(row).frozen_at

        assert :ok = Images.unfreeze(reload_row(row))
        refute reload_row(row).frozen_at

        assert :ok = Images.purge(reload_row(row))
        refute reload_row(row)
      end
    end

    test "every kind it refuses is refused by all three, loudly",
         %{owner: owner, refused: refused} do
      for kind <- refused do
        # No row is needed: the guard refuses before anything is read.
        row = %ImageRow{id: Vutuv.UUIDv7.generate(), kind: kind, user_id: owner.id}

        for {action, fun} <- [
              {"freeze", &Images.freeze/1},
              {"unfreeze", &Images.unfreeze/1},
              {"purge", &Images.purge/1}
            ] do
          assert_raise ArgumentError, ~r/cannot #{action} an image of kind/, fn -> fun.(row) end
        end
      end
    end
  end

  describe "the picture-row bookkeeping" do
    # A frozen picture's member columns are empty on purpose, which is exactly
    # what the backfill calls an orphan row — and the row is the only record of
    # what the case is about and what an unfreeze has to write back.
    test "the backfill leaves a frozen row standing", %{owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, _case} = Moderation.report_content(reporter, image, notice())

      assert %{"avatar" => tally} = Backfill.run(only: "avatar")
      assert tally.dropped == 0
      assert Repo.get(ImageRow, image.id)
      assert Backfill.check(only: "avatar").kinds["avatar"].orphan_row.count == 0
    end
  end

  describe "looking at a held picture (issue #2031)" do
    # An admin ruling on a copyright claim has to see the picture, and a freeze
    # has moved it out of every tree nginx serves — so `bytes_path/2` is the
    # only way there. It looked for the fingerprinted file name alone, which a
    # picture stored before that scheme does not have: the fallback then asked
    # the member row, which the freeze had just cleared, and the case page drew
    # a broken image. One picture of 1,747 on the current data is on the old
    # scheme, so an admin meets this rarely and cannot place it when they do.
    test "a picture on the pre-fingerprint naming scheme is found in the hold",
         %{tmp: tmp, owner: owner, reporter: reporter} do
      legacy = legacy_avatar_owner(tmp)
      image = avatar_image(legacy)

      assert image.fingerprint == nil

      {:ok, _case} = Moderation.report_content(reporter, image, notice())

      path = Images.bytes_path(image)
      assert is_binary(path), "no path for a held picture on the legacy scheme"
      assert File.exists?(path)
      assert File.read!(path) == "legacy medium bytes"

      # And the fingerprinted case still works, so the fallback did not take
      # the precise answer's place.
      current = avatar_image(owner)
      {:ok, _} = Moderation.report_content(reporter, current, notice())
      assert Images.bytes_path(current) |> File.exists?()
    end

    # `held_image_ids/0` handed every directory entry on as an image id, and a
    # non-UUID in `where: i.id in ^ids` raises — so one stray file in the hold
    # root killed the whole reconcile pass, every fifteen minutes, with the
    # sweeper's later steps never running.
    test "a stray entry in the hold root does not stop the reconcile pass",
         %{tmp: tmp, owner: owner, reporter: reporter} do
      image = avatar_image(owner)
      {:ok, _case} = Moderation.report_content(reporter, image, notice())

      # The freeze above created the hold root; this lands beside the real hold.
      File.write!(Path.join([tmp, "frozen", ".DS_Store"]), "not an image id")

      assert :ok = Images.reconcile_holds()

      # The real hold is untouched, and the freeze still stands.
      assert Repo.get!(ImageRow, image.id).frozen_at
      assert held_files(tmp, image) != []
    end
  end

  describe "the report form" do
    test "an image may be reported for copyright" do
      assert "copyright" in Report.categories_for("image")
    end

    test "a picture nobody owns is not reportable", %{reporter: reporter} do
      # The kinds #2015 brings have no member owner, so there is nobody to
      # strike and nothing to freeze.
      orphan = %ImageRow{id: Vutuv.UUIDv7.generate(), kind: "avatar", user_id: nil}
      refute Moderation.can_report?(reporter, orphan)
    end
  end
end
