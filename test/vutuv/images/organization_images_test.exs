defmodule Vutuv.Images.OrganizationImagesTest do
  @moduledoc """
  The third of the four kinds #2015 moves into the shared `images` table
  (issue #2053): a logo, a cover or a description picture on an organization
  page is a row there beside its own row, kept in step by every write, and
  nothing about how it is stored or served has moved.

  The shape is #2054's and #2052's — the join is the `token` both rows carry,
  the mirror is one upsert and one delete, and the registry in `Vutuv.Images`
  is what the backfill reads. **What is new here is who owns the picture.** A
  post photo and a job-posting picture belong to the member who uploaded them;
  a page's logo belongs to the *page*, which is why `organization_images.user_id`
  is nullable and `ON DELETE SET NULL` while `images.user_id` is NOT NULL-ish
  and `ON DELETE CASCADE`. Copying the uploader into `images.user_id` would
  therefore arm a cascade that deletes a page's logo the day its uploader
  closes their account — so the owner here is `organization_id`, the uploader
  rides in `uploader_user_id`, and a check constraint keeps `user_id` empty.

  Not async: the upload path writes files, so the module holds the global
  `:uploads_dir_prefix` down for its lifetime.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.ImageHelpers
  alias Vutuv.Images
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Repo

  @kind "organization_image"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_org_images_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    put_config(:verify_organization_domains, true)
    on_exit(fn -> File.rm_rf(tmp) end)

    owner = insert(:activated_user)
    {:ok, tmp: tmp, owner: owner, organization: active_organization_for(owner)}
  end

  # Returns the page and the `organization_images` row the upload just wrote,
  # whichever of the two outcomes it took: the released logo and the one still
  # waiting for the AI gate are the same newest row, and ids are UUID v7, so
  # newest is last written.
  defp upload!(organization, user, tmp) do
    src = Path.join(tmp, "logo-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(120, 90, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)

    {_outcome, organization} = Organizations.store_logo(organization, user, src, "logo.jpg")
    {organization, newest_image(organization)}
  end

  defp newest_image(organization) do
    Repo.one!(
      from(i in OrganizationImage,
        where: i.organization_id == ^organization.id,
        order_by: [desc: i.id],
        limit: 1
      )
    )
  end

  defp mirror(picture), do: ImageHelpers.mirror_row(@kind, picture)

  # The upload enqueued this itself when moderation is on; a second insert
  # would collide with the one-open-scan-per-asset index.
  defp open_scan(image), do: ImageScans.latest_for(@kind, image.id)

  describe "the row beside the row" do
    # Field by field off the registry rather than off a list written a second
    # time here, so a field added to `@mirrored` and forgotten on the request
    # path fails this without anybody editing the test.
    test "an upload writes one, column for column", ctx do
      {_organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)

      assert %ImageRow{} = row = mirror(image)
      assert row.kind == @kind
      assert row.id != image.id
      assert row.frozen_at == nil

      for {field, column} <-
            Enum.zip(Images.mirror_source(@kind).fields, Images.mirror_columns(@kind)) do
        assert Map.fetch!(row, field) == Map.fetch!(image, column),
               "#{field} drifted: #{inspect(Map.fetch!(row, field))} != " <>
                 inspect(Map.fetch!(image, column))
      end
    end

    # The whole point of this kind. `images.user_id` means "a member owns this"
    # and cascades on account deletion; a page's picture has no member owner,
    # so it stays empty and the page answers instead.
    test "the page owns it, the member only uploaded it", ctx do
      {organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      row = mirror(image)

      assert row.organization_id == organization.id
      assert row.uploader_user_id == ctx.owner.id
      assert row.user_id == nil
    end

    test "the AI gate's release follows", ctx do
      put_config(:moderate_images, true)
      {_organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)

      assert mirror(image).moderation == "pending"

      assert :ok = ImageSubjects.apply_approved(open_scan(image))

      assert mirror(image).moderation == "approved"
    end
  end

  describe "the row goes when the picture goes" do
    test "a logo the page replaced", ctx do
      {organization, first} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      assert mirror(first)

      {_organization, second} = upload!(organization, ctx.owner, ctx.tmp)

      refute Repo.get(OrganizationImage, first.id)
      refute mirror(first)
      assert mirror(second)
    end

    test "a logo the page removed", ctx do
      {organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      assert mirror(image)

      {:ok, _organization} = Organizations.remove_logo(organization)

      refute Repo.get(OrganizationImage, image.id)
      refute mirror(image)
    end

    test "a picture the AI gate rejected", ctx do
      put_config(:moderate_images, true)
      {_organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      assert mirror(image)

      assert :ok = ImageSubjects.apply_rejected(open_scan(image))

      refute Repo.get(OrganizationImage, image.id)
      refute mirror(image)
    end

    test "a page that is deleted", ctx do
      {organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      assert mirror(image)

      {:ok, _organization} = Organizations.delete_organization(organization)

      refute Repo.get(OrganizationImage, image.id)
      refute mirror(image)
    end

    # The one that separates this kind from the other three. A page outlives
    # the member who uploaded its logo, so the picture and both its rows have
    # to as well — only the uploader is forgotten.
    test "but NOT when the member who uploaded it deletes their account", ctx do
      {_organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      assert mirror(image)

      {:ok, _user} = Accounts.delete_user(ctx.owner)

      assert %OrganizationImage{user_id: nil} = Repo.get(OrganizationImage, image.id)
      assert %ImageRow{uploader_user_id: nil} = row = mirror(image)
      assert row.organization_id == ctx.organization.id
    end
  end

  describe "the owner column says who owns a page's picture" do
    # A check constraint rather than a comment: `Vutuv.Images.mirror/2` writes
    # through `insert_all`, so no changeset stands between a future author and
    # the cascade that would delete a page's logo with its uploader's account.
    test "the database refuses a member-owned one", ctx do
      # Written the way the mirror writes — `insert_all`, no changeset — because
      # that is the path a future author would take the `user_id` down.
      now = NaiveDateTime.utc_now(:second)

      assert_raise Postgrex.Error, ~r/images_organization_kind_has_no_member_owner/, fn ->
        Repo.insert_all(ImageRow, [
          %{
            id: Vutuv.UUIDv7.generate(),
            kind: @kind,
            token: Vutuv.Uploads.gen_token(),
            user_id: ctx.owner.id,
            organization_id: ctx.organization.id,
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end
  end

  describe "nothing about serving moved" do
    test "the URL is the one it always was", ctx do
      {_organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      assert mirror(image)

      assert OrganizationImage.token_url(image.token, "feed") ==
               "/organization_images/#{image.token}/feed.avif"
    end

    test "it is still served through its authorizing proxy", _ctx do
      assert Images.serving(@kind) == :proxy
    end

    # The report form addresses a picture by its `images` row id, and until
    # this release no row of this kind existed. Now one does, and
    # `Vutuv.Images.freeze/1` has no clause for it: the takedown is the next
    # release's work, and an organization is not a member, so the profile
    # strategy cannot simply be pointed at it (issue #2057).
    test "a copyright report cannot name one yet — the freeze has no path for it", ctx do
      {_organization, image} = upload!(ctx.organization, ctx.owner, ctx.tmp)
      row = mirror(image)
      reporter = insert(:activated_user)

      refute Images.takedown_ready?(row)
      refute Vutuv.Moderation.can_report?(reporter, row)

      assert {:error, :not_allowed} =
               Vutuv.Moderation.report_content(reporter, row, %{
                 "category" => "copyright",
                 "details" => "That is our logo."
               })
    end
  end
end
