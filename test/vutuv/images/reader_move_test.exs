defmodule Vutuv.Images.ReaderMoveTest do
  @moduledoc """
  Every reader of a profile picture answers from the `images` row (issue
  #2027), so the deploy after this one can drop the member row's four columns
  per kind.

  The whole file is calibrated the same way: it blanks the four member columns
  and leaves the row alone — which is exactly the state the column drop
  creates — and then asks every reader what it shows. Before this change every
  one of them answered "no picture"; the columns were the source of truth.
  """
  # Not async: flips the global :uploads_dir_prefix and :moderate_images.
  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_reader_move_#{System.unique_integer([:positive])}")
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    user = insert(:activated_user)
    insert(:email, user: user)

    {:ok, user: user}
  end

  defp jpeg_upload(name \\ "selfie.jpg", color \\ [10, 120, 200]) do
    src = Path.join(System.tmp_dir!(), "reader_move_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: color)
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: name, path: src, content_type: "image/jpeg"}
  end

  # The state the contract deploy creates: the row is intact, the four member
  # columns of that kind are gone. Every assertion in this file is taken with
  # the columns in this state, so a reader that still consults them fails.
  defp drop_member_columns(user, kind) do
    cols = Images.member_columns(kind)

    {1, _} =
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [{cols.file, nil}, {cols.fingerprint, nil}, {cols.crop, nil}, {cols.moderation, nil}]
      )

    Repo.get!(User, user.id)
  end

  defp with_avatar(user, upload \\ nil) do
    {:ok, user} = Accounts.update_user(user, %{avatar: upload || jpeg_upload()})
    user
  end

  defp with_cover(user) do
    {:ok, user} =
      Accounts.update_user(user, %{cover_photo: jpeg_upload("wide.jpg", [200, 30, 30])})

    user
  end

  describe "the avatar URL comes from the row" do
    test "display_url, url and picture answer with the columns gone", %{user: user} do
      user = with_avatar(user)
      fingerprint = user.avatar_fingerprint
      before = Vutuv.Avatar.display_url(user, :medium)

      user = drop_member_columns(user, "avatar")

      assert Vutuv.Avatar.display_url(user, :medium) == before

      assert Vutuv.Avatar.url(user, :medium) ==
               "/avatars/#{user.id}/#{user.username}-medium-#{fingerprint}.avif"

      assert Vutuv.Avatar.picture(user).src == before
    end

    test "the served file still resolves on disk", %{user: user} do
      user = user |> with_avatar() |> drop_member_columns("avatar")

      path = Vutuv.Avatar.stored_path(user, :medium)
      assert is_binary(path) and File.exists?(path)
    end

    test "a member with no picture at all has no row and no URL", %{user: user} do
      assert Images.member_image(user, "avatar") == nil
      assert Vutuv.Avatar.url(user, :medium) == nil
      assert Vutuv.Avatar.picture(user).src == nil
      assert Vutuv.Avatar.og_jpeg(user) == :error
    end
  end

  describe "the cover URL comes from the row" do
    test "display_url and picture answer with the columns gone", %{user: user} do
      user = with_cover(user)
      fingerprint = user.cover_fingerprint
      before = Vutuv.Cover.display_url(user, :wide)

      user = drop_member_columns(user, "cover")

      assert Vutuv.Cover.display_url(user, :wide) == before

      assert before == "/covers/#{user.id}/#{user.username}-wide-#{fingerprint}.avif"
      assert Vutuv.Cover.picture(user).src == before
    end
  end

  describe "the crop and the derived JPEGs come from the row" do
    test "the vCard's base64 photo and the link-preview JPEG", %{user: user} do
      {:ok, user} =
        Accounts.update_user(user, %{
          "avatar" => jpeg_upload(),
          "avatar_crop" => "0,0,0.5,0.5"
        })

      user = drop_member_columns(user, "avatar")

      assert "data:image/jpeg;base64," <> _rest = Vutuv.Avatar.binary(user, :medium)
      assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Vutuv.Avatar.og_jpeg(user)
      assert Images.member_image(user, "avatar").crop == "0.0000,0.0000,0.5000,0.5000"
    end
  end

  describe "the ActivityPub actor document" do
    test "still advertises the icon with the columns gone", %{user: user} do
      user = user |> with_avatar() |> drop_member_columns("avatar")
      {:ok, actor} = Vutuv.Fediverse.ensure_actor(user)

      doc = Docs.actor(user, actor)

      assert doc["icon"]["url"] == "#{VutuvWeb.Endpoint.url()}/#{user.username}/avatar.jpg"
    end

    test "names no icon for a member without a picture", %{user: user} do
      {:ok, actor} = Vutuv.Fediverse.ensure_actor(user)
      refute Map.has_key?(Docs.actor(user, actor), "icon")
    end
  end

  describe "a row with no fingerprint" do
    # One member on the production copy is still on the pre-fingerprint naming
    # scheme, and the backfill copied that nil verbatim. A nil fingerprint is
    # not "no picture": it is the legacy URL, and it has to keep resolving.
    test "keeps serving the legacy URL", %{user: user} do
      user = with_avatar(user)
      image = Images.member_image(user, "avatar")

      # The shape that row has: a file name, no fingerprint. The legacy files
      # are named for the version, not the fingerprint.
      dir = Path.join(Vutuv.Uploads.uploads_dir_prefix(), "avatars/#{user.id}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "avatar_medium.avif"), "x")
      {:ok, _} = image |> Ecto.Changeset.change(%{fingerprint: nil}) |> Repo.update()

      user = drop_member_columns(user, "avatar")

      assert Vutuv.Avatar.url(user, :medium) =~ "/avatars/#{user.id}/avatar_medium.avif?v="
      assert Vutuv.Avatar.stored_path(user, :medium) == Path.join(dir, "avatar_medium.avif")
    end
  end

  describe "a frozen picture" do
    # A freeze (#2012) clears the member row's four columns, which is what
    # every reader used to notice. Now that they read the row, `frozen_at` is
    # the off switch — so this leaves the member columns filled and only stamps
    # the row.
    test "renders as no picture even while the member columns still name it", %{user: user} do
      user = with_avatar(user)
      image = Images.member_image(user, "avatar")

      {:ok, _} =
        image
        |> Ecto.Changeset.change(%{frozen_at: NaiveDateTime.utc_now(:second)})
        |> Repo.update()

      user = Repo.get!(User, user.id)

      assert user.avatar, "the member columns are deliberately left filled here"
      assert Vutuv.Avatar.url(user, :medium) == nil
      assert Vutuv.Avatar.og_jpeg(user) == :error
      # No picture at all, not the held-picture silhouette: a takedown has to
      # read the way a member who never uploaded one reads, which is what
      # clearing the four member columns used to do.
      assert Vutuv.Avatar.picture(user).src == nil
      assert Vutuv.Images.shown_image(user, "avatar") == nil
    end

    test "a picture the AI gate holds keeps the silhouette instead", %{user: user} do
      put_config(:moderate_images, true)
      user = with_avatar(user)

      assert Vutuv.Avatar.url(user, :medium) == nil
      assert Vutuv.Avatar.picture(user).src != nil, "limbo is not a takedown"
    end
  end

  describe "a picture the AI gate still holds" do
    setup do
      put_config(:moderate_images, true)
      :ok
    end

    test "renders as no picture, and the owner's preview still resolves", %{user: user} do
      user = with_avatar(user)
      assert user.avatar_moderation == "pending"

      user = drop_member_columns(user, "avatar")

      assert Vutuv.Avatar.url(user, :medium) == nil
      assert Vutuv.Avatar.og_jpeg(user) == :error
      assert Images.member_image(user, "avatar").moderation == "pending"
      assert is_binary(Vutuv.Avatar.pending_preview_path(user, :medium))
    end
  end

  describe "a member the backfill has not reached" do
    # The bridge (`Vutuv.Images.member_image/2`). Nothing enforces that an
    # operator ran `mix vutuv.images.backfill` before taking this release — it
    # is not in `scripts/deploy.sh`, not in boot, not in `/health` — so a
    # picture with no row has to keep working off the member row's own columns.
    # Without the bridge every one of these answers "no picture", silently.
    setup %{user: user} do
      user = with_avatar(user)
      fingerprint = user.avatar_fingerprint

      # Exactly the state an un-backfilled installation is in: the columns are
      # filled, the row and the pointer are not.
      {1, _} = Repo.delete_all(from(i in Images.Image, where: i.user_id == ^user.id))

      {1, _} =
        Repo.update_all(from(u in User, where: u.id == ^user.id),
          set: [avatar_image_id: nil]
        )

      {:ok, user: Repo.get!(User, user.id), fingerprint: fingerprint}
    end

    test "still gets their avatar, at the address it always had", ctx do
      %{user: user, fingerprint: fingerprint} = ctx

      assert Vutuv.Avatar.url(user, :medium) ==
               "/avatars/#{user.id}/#{user.username}-medium-#{fingerprint}.avif"

      assert Vutuv.Avatar.picture(user).src == Vutuv.Avatar.url(user, :medium)
      assert Vutuv.Avatar.src(user, :thumb) == Vutuv.Avatar.url(user, :thumb)
      assert {:ok, <<0xFF, 0xD8, _rest::binary>>} = Vutuv.Avatar.og_jpeg(user)
      assert Images.shown_file(user, "avatar") == "selfie.jpg"
    end

    test "the actor document still advertises the icon", %{user: user} do
      {:ok, actor} = Vutuv.Fediverse.ensure_actor(user)

      assert Docs.actor(user, actor)["icon"]["url"] ==
               "#{VutuvWeb.Endpoint.url()}/#{user.username}/avatar.jpg"
    end

    # The one thing the bridge cannot answer: a report names a picture by its
    # row id, and a bridged picture has none. It falls back to reporting the
    # whole profile until the backfill runs.
    test "cannot be reported on its own, having no row to name", %{user: user} do
      assert %Images.Image{id: nil} = Images.member_image(user, "avatar")
      assert Images.reportable_image(user, "avatar") == nil
    end

    # The narrow listing select has to carry what the bridge reads, or a whole
    # page of members loses its faces while single-member pages keep theirs.
    # Asserted against the URL string rather than against another call that
    # would go nil in the same breath.
    test "a listing row bridges too, so a whole page keeps its faces", ctx do
      %{user: user, fingerprint: fingerprint} = ctx

      row =
        Repo.one!(
          from(u in User, where: u.id == ^user.id, select: struct(u, ^User.listing_fields()))
        )

      assert row.avatar_image_id == nil

      assert Vutuv.Avatar.src(row, :thumb) ==
               "/avatars/#{user.id}/#{user.username}-thumb-#{fingerprint}.avif"
    end
  end

  describe "a listing row" do
    # Listing queries select a narrow struct (`User.listing_fields/0`), so the
    # pointer has to be in that list or a whole page of members loses its
    # pictures at once.
    test "carries the pointer, so it resolves an avatar", %{user: user} do
      user = with_avatar(user)

      row =
        Repo.one!(
          from(u in User, where: u.id == ^user.id, select: struct(u, ^User.listing_fields()))
        )

      assert row.avatar_image_id
      assert Vutuv.Avatar.url(row, :thumb) == Vutuv.Avatar.url(user, :thumb)
    end
  end

  describe "a preloaded association costs no query" do
    test "member_image/2 takes the preload when it is there", %{user: user} do
      user = user |> with_avatar() |> Repo.preload(:avatar_image)

      assert %Images.Image{} = user.avatar_image
      assert Images.member_image(user, "avatar").id == user.avatar_image.id
    end
  end
end
