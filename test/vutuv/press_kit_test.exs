defmodule Vutuv.PressKitTest do
  @moduledoc """
  The press-kit picture (issue #2083): the first kind whose **only** home is the
  shared `images` table. Every kind before it arrived there as a mirror of a
  table of its own (#2015) or as columns on a parent row, so this is also the
  first row here that no second write has to be kept in step with.

  What the tests below hold, in the order the issue states it: the row is born
  pending and invisible until a verdict releases it; a member or a page owns it
  and never both; a photo may only be a container
  `Vutuv.Uploads.MetadataStrip` can take apart, so its download is always the
  cleaned original; a logo may be an SVG, which leaves only as an attachment
  beside a PNG rendering; and the caps are configuration, not constants.

  Not async: the upload path writes files, so the module holds the global
  `:uploads_dir_prefix` down for its lifetime.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Images
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.PressKit
  alias Vutuv.PressKitStore
  alias Vutuv.Repo
  alias Vutuv.Uploads
  alias Vutuv.Uploads.MetadataStrip
  alias Vutuv.Uploads.Spec

  @kind "press_kit"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_press_kit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    put_config(:verify_organization_domains, true)
    # The AI gate is off in the test environment, and "born pending" is exactly
    # what this module is about. Nothing here enqueues a scan (#2084 wires
    # that), so turning it on only decides the state a fresh row starts in.
    put_config(:moderate_images, true)
    on_exit(fn -> File.rm_rf(tmp) end)

    owner = insert(:activated_user)
    {:ok, tmp: tmp, owner: owner}
  end

  defp photo_file(tmp, name \\ "portrait.jpg") do
    path = Path.join(tmp, "#{System.unique_integer([:positive])}-#{name}")
    {:ok, img} = Image.new(600, 400, color: [200, 40, 40])
    {:ok, _} = Image.write(img, path)
    {path, name}
  end

  defp svg_file(tmp) do
    path = Path.join(tmp, "#{System.unique_integer([:positive])}-logo.svg")

    File.write!(path, """
    <svg xmlns="http://www.w3.org/2000/svg" width="240" height="80" viewBox="0 0 240 80">
      <rect width="240" height="80" fill="#0a5" />
    </svg>
    """)

    {path, "logo.svg"}
  end

  defp add_photo(owner, uploader, tmp, attrs \\ %{}) do
    PressKit.create(owner, uploader, photo_file(tmp), Map.merge(base_attrs(), attrs))
  end

  defp base_attrs do
    %{"credit" => "Foto: Ada King", "caption" => "Am Schreibtisch", "rights_confirmed" => "true"}
  end

  describe "a press photo is a row on the shared images table (issue #2083)" do
    test "it is born pending, owned by the member, with its files under its token",
         %{owner: owner, tmp: tmp} do
      assert {:ok, %ImageRow{} = photo} = add_photo(owner, owner, tmp)

      assert photo.kind == @kind
      assert photo.user_id == owner.id
      assert photo.organization_id == nil
      assert photo.uploader_user_id == nil
      assert photo.logo == false
      assert photo.position == 0
      assert photo.credit == "Foto: Ada King"
      assert photo.caption == "Am Schreibtisch"
      assert photo.rights_confirmed_at
      assert photo.width == 600 and photo.height == 400
      assert photo.size_bytes > 0

      # The trap the issue names: invisible until a verdict releases it.
      assert photo.moderation == "pending"
      refute PressKit.visible_to?(photo, nil)
      assert PressKit.visible_to?(photo, owner)

      dir = Uploads.disk_dir(Path.join("press_kit", photo.token))
      assert File.exists?(Path.join(dir, "thumb.avif"))
      assert File.exists?(Path.join(dir, "large.avif"))
    end

    test "the kind is declared, proxied, and has no takedown yet", %{owner: owner, tmp: tmp} do
      assert @kind in Images.kinds()
      assert Images.serving(@kind) == :proxy
      refute Images.mirrored?(@kind)

      {:ok, photo} = add_photo(owner, owner, tmp)
      # #2084 wires the freeze; until then the report gate must refuse the kind
      # rather than open a case whose uphold raises.
      refute Images.takedown_ready?(photo)
    end

    test "an upload without the rights confirmation is refused", %{owner: owner, tmp: tmp} do
      assert {:error, changeset} =
               PressKit.create(owner, owner, photo_file(tmp), %{"credit" => "Foto: Ada King"})

      assert errors_on(changeset)[:rights_confirmed]
      assert Repo.aggregate(from(i in ImageRow, where: i.kind == @kind), :count) == 0
    end

    test "positions count up and the cap refuses one photo too many",
         %{owner: owner, tmp: tmp} do
      for index <- 0..(PressKit.max_photos() - 1) do
        assert {:ok, photo} = add_photo(owner, owner, tmp)
        assert photo.position == index
      end

      assert {:error, :too_many} = add_photo(owner, owner, tmp)
      assert length(PressKit.photos(owner)) == PressKit.max_photos()
    end
  end

  describe "a page's press picture belongs to the page (issue #2087 builds on this)" do
    setup %{owner: owner} do
      {:ok, organization: active_organization_for(owner)}
    end

    test "the page owns the row and the uploader only rides along",
         %{owner: owner, organization: organization, tmp: tmp} do
      assert {:ok, photo} = add_photo(organization, owner, tmp)

      # `images.user_id` cascades, so naming the uploader there would delete a
      # page's press photo the day that colleague closes their account.
      assert photo.user_id == nil
      assert photo.organization_id == organization.id
      assert photo.uploader_user_id == owner.id

      assert Enum.map(PressKit.photos(organization), & &1.id) == [photo.id]
    end

    test "the database refuses a row naming both a member and a page",
         %{owner: owner, organization: organization} do
      assert_raise Ecto.ConstraintError, ~r/images_press_kit_has_one_owner/, fn ->
        Repo.insert!(declared(user_id: owner.id, organization_id: organization.id))
      end
    end

    test "the database refuses a row naming neither" do
      assert_raise Ecto.ConstraintError, ~r/images_press_kit_has_one_owner/, fn ->
        Repo.insert!(declared([]))
      end
    end

    test "the database refuses a row on neither shelf and one nobody released",
         %{owner: owner} do
      assert_raise Ecto.ConstraintError, ~r/images_press_kit_declared/, fn ->
        Repo.insert!(%ImageRow{kind: @kind, token: Uploads.gen_token(), user_id: owner.id})
      end
    end

    # Everything the second constraint asks for, so a failure can only be the
    # owner one — a raw insert missing both would trip whichever Postgres
    # happens to check first.
    defp declared(owner_columns) do
      struct!(
        %ImageRow{
          kind: @kind,
          token: Uploads.gen_token(),
          logo: false,
          rights_confirmed_at: NaiveDateTime.utc_now(:second)
        },
        owner_columns
      )
    end
  end

  describe "what a press photo may be" do
    test "exactly the containers the metadata stripper can take apart" do
      assert Enum.all?(PressKit.photo_extensions(), &MetadataStrip.supported?/1)

      # The other direction: nothing the stripper handles is left out, or a
      # member would be refused a file whose download we could have cleaned.
      assert Enum.sort(PressKit.photo_extensions()) == ~w(.jpeg .jpg .png .webp)
    end

    test "a container the stripper cannot clean is refused at the gate",
         %{owner: owner, tmp: tmp} do
      {path, _name} = photo_file(tmp)

      assert {:error, :invalid_file} =
               PressKit.create(owner, owner, {path, "shot.heic"}, base_attrs())
    end

    test "the download is the cleaned original, not the served version",
         %{owner: owner, tmp: tmp} do
      {:ok, photo} = add_photo(owner, owner, tmp)

      assert {path, ".jpg"} = PressKitStore.download_file(photo)
      assert File.exists?(path)
      # Same pixels, no metadata: the stripper's own output, byte for byte.
      original = PressKitStore.original_path(photo.token)
      assert File.read!(path) == MetadataStrip.strip(original, ".jpg")
    end
  end

  describe "a logo" do
    test "may be an SVG, handed out as the vector beside a PNG rendering",
         %{owner: owner, tmp: tmp} do
      assert {:ok, logo} =
               PressKit.create(
                 owner,
                 owner,
                 svg_file(tmp),
                 Map.merge(base_attrs(), %{"logo" => "true"})
               )

      assert logo.logo == true
      assert logo.position == 0

      assert {svg, ".svg"} = PressKitStore.download_file(logo)
      assert File.read!(svg) =~ "<svg"

      assert {png, ".png"} = PressKitStore.png_download_file(logo)
      assert <<137, "PNG\r\n", 26, 10, _rest::binary>> = File.read!(png)
    end

    test "a PNG logo hands out its cleaned original for both", %{owner: owner, tmp: tmp} do
      path = Path.join(tmp, "mark.png")
      {:ok, img} = Image.new(240, 80, color: [0, 90, 60])
      {:ok, _} = Image.write(img, path)

      assert {:ok, logo} =
               PressKit.create(owner, owner, {path, "mark.png"}, %{
                 "logo" => "true",
                 "rights_confirmed" => "true"
               })

      assert {cleaned, ".png"} = PressKitStore.download_file(logo)
      assert PressKitStore.png_download_file(logo) == {cleaned, ".png"}
    end

    test "logos are counted and capped apart from photos", %{owner: owner, tmp: tmp} do
      for _ <- 1..PressKit.max_logos() do
        assert {:ok, _} =
                 PressKit.create(
                   owner,
                   owner,
                   svg_file(tmp),
                   Map.merge(base_attrs(), %{"logo" => "true"})
                 )
      end

      assert {:error, :too_many} =
               PressKit.create(
                 owner,
                 owner,
                 svg_file(tmp),
                 Map.merge(base_attrs(), %{"logo" => "true"})
               )

      # The photo budget is untouched by a full logo shelf.
      assert {:ok, _} = add_photo(owner, owner, tmp)
      assert length(PressKit.logos(owner)) == PressKit.max_logos()
      assert length(PressKit.photos(owner)) == 1
    end
  end

  describe "who may see one" do
    test "released is public, frozen is nobody's", %{owner: owner, tmp: tmp} do
      {:ok, photo} = add_photo(owner, owner, tmp)

      released = Repo.update!(Ecto.Changeset.change(photo, moderation: "approved"))
      assert PressKit.visible_to?(released, nil)

      frozen =
        Repo.update!(Ecto.Changeset.change(released, frozen_at: NaiveDateTime.utc_now(:second)))

      refute PressKit.visible_to?(frozen, nil)
      refute PressKit.visible_to?(frozen, owner)
    end

    test "a stranger never sees a pending picture, a page's team does",
         %{owner: owner, tmp: tmp} do
      organization = active_organization_for(owner)
      stranger = insert(:activated_user)

      {:ok, photo} = add_photo(organization, owner, tmp)

      assert PressKit.visible_to?(photo, owner)
      refute PressKit.visible_to?(photo, stranger)
      refute PressKit.visible_to?(photo, nil)
    end

    # A press kit is as public as the thing it belongs to. Without this a page
    # taken off the public site would go on handing out its press photos to
    # anonymous readers, which is the opposite of what taking it off means.
    test "a page that is not on the public site takes its press kit with it",
         %{owner: owner, tmp: tmp} do
      organization = active_organization_for(owner)
      {:ok, photo} = add_photo(organization, owner, tmp)
      released = Repo.update!(Ecto.Changeset.change(photo, moderation: "approved"))

      assert PressKit.visible_to?(released, nil)

      Repo.update!(Ecto.Changeset.change(organization, frozen_at: NaiveDateTime.utc_now(:second)))

      refute PressKit.visible_to?(released, nil)
      # Its team still sees it — they are the people who have to deal with it.
      assert PressKit.visible_to?(released, owner)
    end
  end

  describe "what the store derives and what it serves" do
    # The bug this repeats for a third store: a store deriving from a version
    # list its own URL layer does not know writes files nothing can ever serve.
    # This is the only store with **two** Spec keys, so it had two chances at it
    # — which is why both whitelists are read off `Spec` at compile time rather
    # than written out beside it.
    test "each shelf serves exactly the versions its Spec key derives" do
      for {logo?, type} <- [{false, :press_kit}, {true, :press_kit_logo}] do
        derived = type |> Spec.versions() |> Enum.map(&to_string(&1.name)) |> Enum.sort()
        served = logo? |> PressKitStore.versions() |> Enum.sort()

        assert derived == served,
               "the #{if logo?, do: "logo", else: "photo"} shelf serves " <>
                 "#{inspect(served)} but #{inspect(type)} derives #{inspect(derived)}"
      end
    end

    # A press photo is the same picture in the same two slots a post photo is,
    # so the two share one list rather than a copy of it.
    test "a press photo is stored at the post photo's sizes" do
      assert Spec.versions(:press_kit) == Spec.versions(:post_image)
    end

    # A wordmark is wide; a square thumb would cut it in half.
    test "nothing crops a logo" do
      for spec <- Spec.versions(:press_kit_logo) do
        assert {:box_down, _size} = spec.fit
      end
    end
  end

  describe "the caps are configuration" do
    test "an installation can lower every one of them" do
      put_config(:press_kit, max_photos: 2, max_logos: 1, max_filesize: 1_000_000)

      assert PressKit.max_photos() == 2
      assert PressKit.max_logos() == 1
      assert PressKit.max_filesize() == 1_000_000
    end

    test "the defaults are the ones the issue names" do
      assert PressKit.max_photos() == 10
      assert PressKit.max_filesize() == 30_000_000
    end

    test "a file over the cap never reaches the disk", %{owner: owner, tmp: tmp} do
      put_config(:press_kit, max_filesize: 10)

      assert {:error, :too_large} = add_photo(owner, owner, tmp)
      assert Repo.aggregate(from(i in ImageRow, where: i.kind == @kind), :count) == 0
    end
  end

  describe "deleting" do
    test "takes the row and every file with it", %{owner: owner, tmp: tmp} do
      {:ok, photo} = add_photo(owner, owner, tmp)
      dir = Uploads.disk_dir(Path.join("press_kit", photo.token))
      assert File.exists?(dir)

      assert :ok = PressKit.delete(photo)
      refute Repo.get(ImageRow, photo.id)
      refute File.exists?(dir)
      refute PressKitStore.original_path(photo.token)
    end

    # The rows cascade on `images.organization_id`; the files do not, and unlike a
    # logo (whose token sits on the page row) a press picture is named only by
    # its own row — so the tokens have to be read before the delete or nothing
    # ever names those files again.
    test "a deleted page takes its press kit off the disk", %{owner: owner, tmp: tmp} do
      organization = active_organization_for(owner)
      {:ok, photo} = add_photo(organization, owner, tmp)
      dir = Uploads.disk_dir(Path.join("press_kit", photo.token))
      assert File.exists?(dir)

      {:ok, _} = Vutuv.Organizations.delete_organization(organization)

      refute Repo.get(ImageRow, photo.id)
      refute File.exists?(dir)
      refute PressKitStore.original_path(photo.token)
    end

    test "a closed account takes its own press kit, a page keeps its own",
         %{owner: owner, tmp: tmp} do
      organization = active_organization_for(owner)
      {:ok, mine} = add_photo(owner, owner, tmp)
      {:ok, theirs} = add_photo(organization, owner, tmp)

      {:ok, _} = Vutuv.Accounts.delete_user(owner)

      refute Repo.get(ImageRow, mine.id)
      refute File.exists?(Uploads.disk_dir(Path.join("press_kit", mine.token)))

      kept = Repo.get!(ImageRow, theirs.id)
      assert kept.uploader_user_id == nil
      assert File.exists?(Uploads.disk_dir(Path.join("press_kit", kept.token)))
    end
  end
end
