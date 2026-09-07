defmodule Vutuv.Images.JobPostingImagesTest do
  @moduledoc """
  The first of the four kinds #2015 moves into the shared `images` table
  (issue #2054): a job-posting picture is a row there beside its own row, kept
  in step by every write, and nothing about how it is stored or served has
  moved.

  Not async: the upload path writes files, so the module holds the global
  `:uploads_dir_prefix` down for its lifetime.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.JobsHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.ImageHelpers
  alias Vutuv.Images
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Repo

  @kind "job_posting_image"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_jp_images_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  defp upload!(user, tmp) do
    src = Path.join(tmp, "src-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(64, 48, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)
    {:ok, image} = Jobs.create_pending_image(user, src, "office.jpg")
    image
  end

  defp mirror(picture), do: ImageHelpers.mirror_row(@kind, picture)

  describe "the row beside the row" do
    test "an upload writes one, column for column", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)

      assert %ImageRow{} = row = mirror(image)
      assert row.kind == @kind
      assert row.user_id == user.id
      assert row.job_posting_id == nil
      assert row.token == image.token
      assert row.alt == image.alt
      assert row.position == image.position
      assert row.width == image.width
      assert row.height == image.height
      assert row.content_type == image.content_type
      assert row.size_bytes == image.size_bytes
      assert row.moderation == image.moderation
      assert row.frozen_at == nil
    end

    test "its id is a UUID v7 of its own, not the gallery row's", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)
      row = mirror(image)

      assert row.id != image.id
      assert {:ok, <<_::48, 7::4, _::76>>} = Ecto.UUID.dump(row.id)
    end

    test "attaching the picture to a posting moves the parent across", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Backend Engineer (m/w/d)"})

      {:ok, posting} = Jobs.publish(draft, user, job_attrs(%{"image_ids" => [image.id]}))

      assert mirror(image).job_posting_id == posting.id
    end

    test "an edited alt text follows", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)

      {:ok, _} = Jobs.update_image_alt(image, "Unser Büro in Köln")

      assert mirror(image).alt == "Unser Büro in Köln"
    end

    test "the AI gate's release follows", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)

      Repo.update_all(from(i in JobPostingImage, where: i.id == ^image.id),
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
    test "a pending upload the member discards", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)

      :ok = Jobs.delete_pending_image(image)

      refute mirror(image)
    end

    test "a picture the editor removed on save", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Backend Engineer (m/w/d)"})
      {:ok, posting} = Jobs.publish(draft, user, job_attrs(%{"image_ids" => [image.id]}))

      {:ok, _} = Jobs.update_posting(posting, user, %{"image_ids" => []})

      refute Repo.get(JobPostingImage, image.id)
      refute mirror(image)
    end

    test "a pending upload nobody ever attached", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)
      old = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -25 * 3600, :second)

      Repo.update_all(from(i in JobPostingImage, where: i.id == ^image.id),
        set: [inserted_at: old]
      )

      assert Jobs.sweep_pending_images() == 1

      refute mirror(image)
    end

    test "a posting that is deleted", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)
      {:ok, draft} = Jobs.create_draft(user, %{"title" => "Backend Engineer (m/w/d)"})
      {:ok, posting} = Jobs.publish(draft, user, job_attrs(%{"image_ids" => [image.id]}))

      {:ok, _} = Jobs.delete_job_posting(posting)

      refute mirror(image)
    end

    test "a picture the AI gate rejected", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)
      scan = insert(:image_scan, kind: @kind, subject_id: image.id, owner_user_id: user.id)

      assert :ok = ImageSubjects.apply_rejected(scan)

      refute Repo.get(JobPostingImage, image.id)
      refute mirror(image)
    end
  end

  describe "the mirror carries the whole picture" do
    # The mirror copies by name, and `Map.fetch!/2` makes a name listed in
    # `Vutuv.Images` that the source does not have raise. The other direction —
    # a column added to `job_posting_images` and never listed — nothing can
    # see: the mirror simply would not carry it, and the backfill's own
    # comparison reads the same list, so it would agree that all is well. This
    # is what notices, and the deploy that retires the old table is what it
    # protects: a column nobody mirrored is a column that is lost then.
    #
    # A column that genuinely belongs to the old row alone goes on the
    # exclusion list below, with the reason.
    test "every column of the gallery row is mirrored, or excluded on purpose" do
      not_mirrored = [
        # The two rows are separate records with separate lifetimes; the mirror
        # mints a UUID v7 of its own and stamps its own timestamps.
        :id,
        :inserted_at,
        :updated_at
      ]

      source = Vutuv.Images.mirror_source(@kind)
      columns = source.schema.__schema__(:fields)

      assert Enum.sort(columns) == Enum.sort(source.fields ++ not_mirrored),
             """
             `job_posting_images` and the mirror have drifted.

             columns:  #{inspect(Enum.sort(columns))}
             mirrored: #{inspect(Enum.sort(source.fields))}
             excluded: #{inspect(Enum.sort(not_mirrored))}

             Add the column to `Vutuv.Images`' mirror entry (and to the
             `images` table in a migration), or to `not_mirrored` here with the
             reason it belongs to the old row alone.
             """
    end

    test "and every mirrored name is a column of the images row too" do
      source = Vutuv.Images.mirror_source(@kind)
      assert source.fields -- ImageRow.__schema__(:fields) == []
    end
  end

  describe "nothing about serving moved" do
    test "the URL is the one it always was", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)

      assert JobPostingImage.url(image, "thumb") ==
               "/job_posting_images/#{image.token}/thumb.avif"
    end

    test "the kind is served through its authorizing proxy, not off disk" do
      assert Images.serving(@kind) == :proxy
    end

    # The report form addresses a picture by its `images` row id, and until this
    # release no row of this kind existed — so nothing could name one. Now one
    # does, and `Vutuv.Images.freeze/1` has no clause for it: the takedown is
    # the contract half's work, not this release's. A report has to be refused
    # rather than accepted into a case whose uphold would raise.
    test "a copyright report cannot name one yet — the freeze has no path for it", %{tmp: tmp} do
      user = poster_fixture()
      image = upload!(user, tmp)
      reporter = insert(:activated_user)
      row = mirror(image)

      # Both the form (`ReportController.new`) and the submit go through
      # `can_report?/2`, so the picture cannot even be previewed for a notice.
      refute Vutuv.Moderation.can_report?(reporter, row)

      assert {:error, :not_allowed} =
               Vutuv.Moderation.report_content(reporter, row, %{
                 "category" => "copyright",
                 "details" => "That is my photograph."
               })
    end

    test "and the freeze itself refuses rather than half-hiding it", %{tmp: tmp} do
      user = poster_fixture()
      row = mirror(upload!(user, tmp))

      assert_raise ArgumentError, ~r/job_posting_image/, fn -> Images.freeze(row) end
    end
  end
end
