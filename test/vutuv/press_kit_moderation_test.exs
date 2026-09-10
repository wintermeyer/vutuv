defmodule Vutuv.PressKitModerationTest do
  @moduledoc """
  A press picture through the AI gate and the copyright freeze (issue #2084).

  #2083 gave the kind a row and a proxy but no way out of limbo: nothing
  enqueued a scan, so a row was born `"pending"` and stayed there for ever on
  an installation with the gate on, and `Vutuv.Images.takedown_ready?/1`
  answered false, so no copyright case could name one. What the tests below
  hold is the whole life of such a row: it is queued at upload, a safe verdict
  releases it, an unsafe one wipes every byte and tells whoever uploaded it,
  the drift repair finds one nobody queued, and the freeze moves the files into
  the hold and back without deleting one.

  Not async: the upload path writes files and the AI gate is a global flag, and
  the SQL sandbox rolls back neither.
  """
  use Vutuv.DataCase, async: false

  import Ecto.Query
  import Vutuv.OrganizationsHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Activity
  alias Vutuv.Images
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.PressKit
  alias Vutuv.PressKitStore
  alias Vutuv.Repo
  alias Vutuv.Uploads

  @kind "press_kit"
  @safe {:ok, %{safe?: true, category: "safe"}}
  @unsafe {:ok, %{safe?: false, category: "nudity"}}

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_press_mod_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    put_config(:moderate_images, true)
    put_config(:verify_organization_domains, true)
    on_exit(fn -> File.rm_rf(tmp) end)

    owner = insert(:activated_user)
    # The rejection notice needs an address to land in.
    insert(:email, user: owner)

    {:ok, tmp: tmp, owner: owner}
  end

  defp photo!(owner, uploader, tmp) do
    path = Path.join(tmp, "shot-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
    {:ok, _} = Image.write(img, path)

    attrs = %{"rights_confirmed" => "true", "credit" => "Foto: Ada King"}
    {:ok, image} = PressKit.create(owner, uploader, {path, "shot.jpg"}, attrs)
    image
  end

  defp scan_of(%ImageRow{id: id}),
    do: Repo.one(from(s in ImageScan, where: s.kind == @kind and s.subject_id == ^id))

  defp served_files(token),
    do: Path.wildcard(Path.join(Uploads.disk_dir("press_kit/#{token}"), "*"))

  defp original_files(token),
    do: Path.wildcard(Path.join(Uploads.disk_dir("originals/press_kit/#{token}"), "*"))

  defp held_files(%ImageRow{id: id}), do: Path.wildcard(Path.join(Uploads.hold_dir(id), "*/*"))

  # `basename => sha256`, so a round trip is compared by contents rather than
  # by "the same number of files turned up".
  defp digests(paths) do
    paths
    |> Enum.reject(&File.dir?/1)
    |> Map.new(&{Path.basename(&1), :crypto.hash(:sha256, File.read!(&1))})
  end

  describe "the scan" do
    test "a fresh press picture is queued for the model that has to clear it", %{
      owner: owner,
      tmp: tmp
    } do
      photo = photo!(owner, owner, tmp)

      assert photo.moderation == "pending"
      assert scan = scan_of(photo)
      assert scan.status == "pending"
      assert scan.owner_user_id == owner.id
    end

    test "a page's picture is queued against the colleague who uploaded it", %{
      owner: owner,
      tmp: tmp
    } do
      # `images.user_id` is empty for a page's row (the member cascade would
      # take the page's photo with the uploader's account), so the scan has to
      # take its owner from `uploader_user_id` — otherwise nobody is told when
      # the file they chose is refused.
      organization = active_organization_for(owner)
      photo = photo!(organization, owner, tmp)

      assert photo.user_id == nil
      assert scan_of(photo).owner_user_id == owner.id
    end

    test "a safe verdict releases the picture and drops its stand-in", %{owner: owner, tmp: tmp} do
      photo = photo!(owner, owner, tmp)
      stand_in = PressKitStore.pixelated_path(photo.token)
      assert File.exists?(stand_in)

      ImageScans.deliver_due(judge: fn _path -> @safe end)

      assert Repo.get!(ImageRow, photo.id).moderation == "approved"
      assert scan_of(photo).status == "approved"
      # The stand-in stood in for a wait that is over; the picture itself stays.
      refute File.exists?(stand_in)
      assert PressKitStore.version_path(photo.token, "large")
    end

    test "an unsafe verdict wipes every byte and tells the uploader", %{owner: owner, tmp: tmp} do
      photo = photo!(owner, owner, tmp)
      flush_emails()

      ImageScans.deliver_due(judge: fn _path -> @unsafe end)

      assert Repo.get(ImageRow, photo.id) == nil
      assert served_files(photo.token) == []
      assert original_files(photo.token) == []

      assert scan_of(photo).status == "rejected"

      assert [email] = flush_emails()
      assert email.subject =~ "An automated check removed an image"
      assert email.text_body =~ "press"

      %{entries: entries} = Activity.notifications_page(owner.id)
      assert Enum.any?(entries, &(&1.kind == "image_rejected" and &1.image_kind == @kind))
    end

    test "the drift repair finds a press picture nobody queued", %{owner: owner, tmp: tmp} do
      photo = photo!(owner, owner, tmp)
      Repo.delete_all(from(s in ImageScan, where: s.subject_id == ^photo.id))

      assert {@kind, photo.id, owner.id, nil} in ImageSubjects.stranded_pending()
      assert ImageScans.repair_drift() >= 1
      assert scan_of(photo).status == "pending"
    end

    test "a frozen picture is not queued again, whatever its moderation says", %{
      owner: owner,
      tmp: tmp
    } do
      # Its files are in the hold, so the scan would find nothing, cancel, and
      # be re-enqueued on the next pass — for ever, on a row that is offline by
      # decision rather than by drift.
      photo = photo!(owner, owner, tmp)
      Repo.delete_all(from(s in ImageScan, where: s.subject_id == ^photo.id))
      :ok = Images.freeze(photo)

      refute Enum.any?(ImageSubjects.stranded_pending(), &(elem(&1, 1) == photo.id))
    end
  end

  describe "the takedown" do
    test "a press picture can be frozen, and a freeze moves rather than deletes", %{
      owner: owner,
      tmp: tmp
    } do
      photo = photo!(owner, owner, tmp)
      assert Images.takedown_ready?(photo)

      :ok = Images.freeze(photo)

      assert %NaiveDateTime{} = Repo.get!(ImageRow, photo.id).frozen_at
      # Nothing a reader can reach is left, and every byte is still on disk.
      assert served_files(photo.token) == []
      assert original_files(photo.token) == []
      assert length(held_files(photo)) > 1
      assert PressKitStore.version_path(photo.token, "large") == nil
      assert PressKitStore.download_file(photo) == nil
    end

    # The originals directory holds **two** files, not one: the upload verbatim
    # and the metadata-stripped `cleaned<ext>` beside it
    # (`Vutuv.Uploads.Originals.cleaned_copy/3`), which is the copy the download
    # hands out. A freeze that took only the original would leave the
    # *deliverable* file on disk while the row read as held, and every
    # assertion above would still be green — so this one names both files and
    # compares the round trip byte for byte.
    test "the cleaned copy travels with the original, and comes back with it",
         %{owner: owner, tmp: tmp} do
      photo = photo!(owner, owner, tmp)
      assert PressKitStore.download_file(photo)

      before = digests(served_files(photo.token) ++ original_files(photo.token))
      assert Enum.any?(Map.keys(before), &(Path.basename(&1) =~ ~r/^cleaned\./))

      :ok = Images.freeze(photo)

      assert served_files(photo.token) == []
      assert original_files(photo.token) == []

      assert digests(held_files(photo)) |> Map.values() |> Enum.sort() ==
               before |> Map.values() |> Enum.sort()

      :ok = Images.unfreeze(Repo.get!(ImageRow, photo.id))

      assert digests(served_files(photo.token) ++ original_files(photo.token)) == before
      assert PressKitStore.download_file(photo)
    end

    test "an unfreeze puts every file back at the URL it had", %{owner: owner, tmp: tmp} do
      photo = photo!(owner, owner, tmp)
      before = served_files(photo.token)

      :ok = Images.freeze(photo)
      :ok = Images.unfreeze(Repo.get!(ImageRow, photo.id))

      assert Repo.get!(ImageRow, photo.id).frozen_at == nil
      assert served_files(photo.token) == before
      assert held_files(photo) == []
      assert PressKitStore.version_path(photo.token, "large")
    end

    test "an upheld case deletes the row, the files and the hold", %{owner: owner, tmp: tmp} do
      photo = photo!(owner, owner, tmp)
      :ok = Images.freeze(photo)

      :ok = Images.purge(Repo.get!(ImageRow, photo.id))

      assert Repo.get(ImageRow, photo.id) == nil
      assert served_files(photo.token) == []
      assert original_files(photo.token) == []
      assert held_files(photo) == []
    end

    test "an interrupted freeze is finished by the standing reconcile", %{owner: owner, tmp: tmp} do
      # The stamp is the intent and the disk is the state: a slot that dies
      # between the two leaves a picture already invisible and files still
      # reachable, which is the half `reconcile_holds/0` finishes.
      photo = photo!(owner, owner, tmp)

      Repo.update_all(from(i in ImageRow, where: i.id == ^photo.id),
        set: [frozen_at: NaiveDateTime.utc_now(:second)]
      )

      :ok = Images.reconcile_holds()

      assert served_files(photo.token) == []
      assert length(held_files(photo)) > 1
    end
  end
end
