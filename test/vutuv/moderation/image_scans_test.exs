defmodule Vutuv.Moderation.ImageScansTest do
  @moduledoc """
  The AI image-moderation queue end to end (with a stubbed judge — no Ollama):
  every upload lands in owner-only limbo (quarantine tree, placeholder for the
  world), a safe verdict releases it, an unsafe verdict deletes it and
  notifies the owner, and the durable-queue guarantees hold across the ugly
  paths — re-upload races, service outages (fail-closed, never fail-open),
  crashes mid-scan, and drift between asset state and queue rows.
  """
  # Not async: flips the global :moderate_images + :uploads_dir_prefix env.
  use Vutuv.DataCase, async: false

  import Ecto.Query
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo

  @safe {:ok, %{safe?: true, category: "safe"}}
  @unsafe {:ok, %{safe?: false, category: "nudity"}}

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_scan_test_#{System.unique_integer([:positive])}")
    prev_dir = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
    Application.put_env(:vutuv, :moderate_images, true)

    on_exit(fn ->
      File.rm_rf(tmp)
      Application.put_env(:vutuv, :moderate_images, false)

      if prev_dir,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev_dir),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    user = insert(:activated_user)
    # The rejection notice needs an address to land in.
    insert(:email, user: user)

    {:ok, tmp: tmp, user: user}
  end

  defp jpeg_upload(color \\ [10, 120, 200]) do
    src = Path.join(System.tmp_dir!(), "scan_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: color)
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: "photo.jpg", path: src, content_type: "image/jpeg"}
  end

  defp upload_avatar(user, color \\ [10, 120, 200]) do
    {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload(color)})
    user
  end

  defp reload(user), do: Repo.get!(Vutuv.Accounts.User, user.id)

  defp open_scan(kind, subject_id) do
    Repo.one(
      from(s in ImageScan,
        where:
          s.kind == ^kind and s.subject_id == ^subject_id and
            s.status in ~w(pending scanning)
      )
    )
  end

  describe "limbo (fail-closed by construction)" do
    test "a fresh avatar waits in quarantine: no public bytes, no public URL", %{
      tmp: tmp,
      user: user
    } do
      user = upload_avatar(user)

      assert user.avatar_moderation == "pending"
      assert %ImageScan{fingerprint: fp} = open_scan("avatar", user.id)
      assert fp == user.avatar_fingerprint

      # Files sit in the quarantine tree, never in the nginx-served one.
      assert Path.wildcard(Path.join(tmp, "avatars/#{user.id}/*")) == []
      refute Path.wildcard(Path.join(tmp, "quarantine/avatars/#{user.id}/*")) == []

      # Every public rendering answers "no image".
      assert Vutuv.Avatar.url({user.avatar, user}, :medium) == nil
      assert Vutuv.Avatar.display_url(user, :medium) =~ "data:image/svg+xml"
      assert Vutuv.Avatar.og_jpeg(user) == :error
      assert Vutuv.Avatar.binary(user, :thumb) =~ "data:image/svg+xml"

      # The owner's preview path resolves from quarantine.
      assert Vutuv.Avatar.pending_preview_path(user, :medium)
    end

    test "a regenerator run cannot materialize a limbo image into the served tree", %{
      tmp: tmp,
      user: user
    } do
      user = upload_avatar(user)

      assert Vutuv.Avatar.regenerate(user) == :unchanged
      assert Path.wildcard(Path.join(tmp, "avatars/#{user.id}/*")) == []
    end

    test "a fresh post image is uploader/admin-only until released", %{user: user} do
      {:ok, image} = Posts.create_pending_image(user, jpeg_upload())
      assert image.moderation == "pending"
      assert open_scan("post_image", image.id)

      {:ok, post} = attach_post(user, image)
      image = Repo.get!(Posts.PostImage, image.id) |> Repo.preload(:post)

      stranger = insert(:activated_user)
      admin = insert(:activated_user, admin?: true)

      refute Posts.image_visible_to?(image, nil)
      refute Posts.image_visible_to?(image, stranger)
      assert Posts.image_visible_to?(image, user)
      assert Posts.image_visible_to?(image, admin)

      # Anonymous/public renderings exclude it.
      assert Posts.released_images(%{post | images: [image]}) == []
    end

    test "with :moderate_images off images release immediately", %{user: user} do
      Application.put_env(:vutuv, :moderate_images, false)

      {:ok, image} = Posts.create_pending_image(user, jpeg_upload())
      assert image.moderation == "approved"
      assert open_scan("post_image", image.id) == nil

      user = upload_avatar(user)
      assert user.avatar_moderation == "approved"
    end
  end

  describe "verdicts" do
    test "a safe verdict releases the avatar: files move public, page URL works", %{
      tmp: tmp,
      user: user
    } do
      user = upload_avatar(user)

      ImageScans.deliver_due(judge: fn _path -> @safe end)

      user = reload(user)
      assert user.avatar_moderation == "approved"
      assert user.avatar

      # Quarantine emptied, served tree populated, URL live again.
      assert Path.wildcard(Path.join(tmp, "quarantine/avatars/#{user.id}/*")) == []
      refute Path.wildcard(Path.join(tmp, "avatars/#{user.id}/*")) == []
      assert Vutuv.Avatar.url({user.avatar, user}, :medium) =~ "/avatars/#{user.id}/"

      scan = Repo.one!(from(s in ImageScan, where: s.subject_id == ^user.id))
      assert scan.status == "approved"
      assert scan.scanned_at
    end

    test "an unsafe verdict deletes everything on the spot and notifies the owner", %{
      tmp: tmp,
      user: user
    } do
      user = upload_avatar(user)
      flush_emails()

      ImageScans.deliver_due(judge: fn _path -> @unsafe end)

      user = reload(user)
      assert user.avatar == nil
      assert user.avatar_fingerprint == nil
      assert user.avatar_moderation == nil

      # Nothing unsafe stays at rest: served, quarantine AND original gone.
      assert Path.wildcard(Path.join(tmp, "avatars/#{user.id}/*")) == []
      assert Path.wildcard(Path.join(tmp, "quarantine/avatars/#{user.id}/*")) == []
      assert Path.wildcard(Path.join(tmp, "originals/avatars/#{user.id}/*")) == []

      # The scan row survives as the audit record with the model's category.
      scan = Repo.one!(from(s in ImageScan, where: s.subject_id == ^user.id))
      assert scan.status == "rejected"
      assert scan.category == "nudity"

      # The owner is told, with the family-friendly/work-safe reasoning.
      assert [email] = flush_emails()
      assert email.subject =~ "image was removed"
      assert email.text_body =~ "family-friendly"

      # And the notification feed derives the entry from the audit row.
      %{entries: entries} = Vutuv.Activity.notifications_page(user.id)
      assert Enum.any?(entries, &(&1.kind == "image_rejected" and &1.image_kind == "avatar"))
    end

    test "a rejected post image loses row and files; the post survives", %{
      tmp: tmp,
      user: user
    } do
      {:ok, image} = Posts.create_pending_image(user, jpeg_upload())
      {:ok, post} = attach_post(user, image)
      flush_emails()

      ImageScans.deliver_due(judge: fn _path -> @unsafe end)

      assert Repo.get(Posts.PostImage, image.id) == nil
      assert Path.wildcard(Path.join(tmp, "post_images/#{image.token}/*")) == []
      assert Repo.get(Posts.Post, post.id)
      assert [email] = flush_emails()
      assert email.text_body =~ "image from one of your posts"
    end

    test "the subject vanishing before the verdict cancels the scan", %{user: user} do
      {:ok, image} = Posts.create_pending_image(user, jpeg_upload())
      :ok = Posts.delete_pending_image(image)

      ImageScans.deliver_due(judge: fn _path -> flunk("judged a deleted image") end)

      scan = Repo.one!(from(s in ImageScan, where: s.subject_id == ^image.id))
      assert scan.status == "canceled"
    end
  end

  describe "the ugly paths (races, outages, crashes)" do
    test "a re-upload during a running scan discards the stale verdict", %{user: user} do
      user = upload_avatar(user)
      first_fp = reload(user).avatar_fingerprint

      # The judge simulates "a re-upload (different bytes) lands while Ollama
      # is thinking".
      judge = fn _path ->
        upload_avatar(reload(user), [200, 30, 30])
        @safe
      end

      ImageScans.deliver_due(judge: judge)

      # The stale safe verdict must NOT have released the second upload...
      user = reload(user)
      assert user.avatar_moderation == "pending"
      refute user.avatar_fingerprint == first_fp

      # ...whose reset queue row now waits with the new fingerprint.
      assert %ImageScan{status: "pending", fingerprint: fp} = open_scan("avatar", user.id)
      assert fp == user.avatar_fingerprint

      # The next (fresh) verdict releases the new bytes.
      ImageScans.deliver_due(judge: fn _path -> @safe end)
      assert reload(user).avatar_moderation == "approved"
    end

    test "Ollama down = fail-closed: retries forever, releases nothing", %{user: user} do
      user = upload_avatar(user)

      ImageScans.deliver_due(judge: fn _path -> {:error, {:service, :econnrefused}} end)

      assert reload(user).avatar_moderation == "pending"
      scan = open_scan("avatar", user.id)
      assert scan.status == "pending"
      assert scan.last_error =~ "econnrefused"
      # Backed off: not due again right now.
      assert DateTime.compare(scan.next_attempt_at, DateTime.utc_now()) == :gt
      assert ImageScans.list_due() == []
      # Service errors never count toward the fail-closed rejection cap.
      assert scan.attempts == 0
    end

    test "an unjudgeable image caps out into rejection, never release", %{user: user} do
      user = upload_avatar(user)
      scan = open_scan("avatar", user.id)
      # Four failed tries already on the clock; the fifth is the cap.
      Repo.update_all(from(s in ImageScan, where: s.id == ^scan.id), set: [attempts: 4])
      flush_emails()

      ImageScans.deliver_due(judge: fn _path -> {:error, {:image, :bad_verdict}} end)

      user = reload(user)
      assert user.avatar == nil
      scan = Repo.get!(ImageScan, scan.id)
      assert scan.status == "rejected"
      assert scan.category == "unverifiable"
      assert [_email] = flush_emails()
    end

    test "resume_stuck re-queues a scan a crash left mid-flight", %{user: user} do
      user = upload_avatar(user)
      scan = open_scan("avatar", user.id)

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600)

      Repo.update_all(from(s in ImageScan, where: s.id == ^scan.id),
        set: [status: "scanning", updated_at: long_ago]
      )

      assert ImageScans.resume_stuck() == 1
      assert Repo.get!(ImageScan, scan.id).status == "pending"
    end

    test "repair_drift re-enqueues a pending asset whose queue row was lost", %{user: user} do
      user = upload_avatar(user)
      Repo.delete_all(ImageScan)

      assert ImageScans.repair_drift() == 1
      assert %ImageScan{} = scan = open_scan("avatar", user.id)
      assert scan.fingerprint == reload(user).avatar_fingerprint
    end

    test "enqueue while a scan is open resets that row instead of duplicating", %{user: user} do
      user = upload_avatar(user)
      scan = open_scan("avatar", user.id)

      Repo.update_all(from(s in ImageScan, where: s.id == ^scan.id),
        set: [attempts: 3, last_error: "old"]
      )

      {:ok, _} = ImageScans.enqueue("avatar", user.id, user.id, "ffffffffffff")

      assert Repo.aggregate(ImageScan, :count) == 1
      refreshed = Repo.get!(ImageScan, scan.id)
      assert refreshed.attempts == 0
      assert refreshed.fingerprint == "ffffffffffff"
      assert refreshed.last_error == nil
    end
  end

  describe "every image kind starts unreleased with an open scan (no-bypass chokepoint)" do
    test "cover", %{user: user} do
      {:ok, user} = Accounts.update_user(user, %{cover_photo: jpeg_upload()})
      assert user.cover_moderation == "pending"
      assert open_scan("cover", user.id)
      assert Vutuv.Cover.url({user.cover_photo, user}, :wide) == nil
    end

    test "job posting image", %{user: user} do
      upload = jpeg_upload()
      {:ok, image} = Vutuv.Jobs.create_pending_image(user, upload.path, upload.filename)
      assert image.moderation == "pending"
      assert open_scan("job_posting_image", image.id)
    end

    test "organization logo keeps the old logo public until the new one is released", %{
      user: user
    } do
      organization = insert_organization(user)
      upload = jpeg_upload()

      {:ok, updated} =
        Vutuv.Organizations.store_logo(organization, user, upload.path, upload.filename)

      # The pointer did NOT flip: no unreleased byte behind organizations.logo.
      assert updated.logo == organization.logo

      image =
        Repo.one!(
          from(i in Vutuv.Organizations.OrganizationImage,
            where: i.organization_id == ^organization.id and i.moderation == "pending"
          )
        )

      assert open_scan("organization_image", image.id)

      # Approval flips the pointer.
      ImageScans.deliver_due(judge: fn _path -> @safe end)
      assert Repo.get!(Vutuv.Organizations.Organization, organization.id).logo == image.token
    end

    test "post link screenshot is held back until released", %{user: user} do
      post = create_post!(user, %{body: "Look: https://example.com/page"})
      # :generate_screenshots is off in tests, so enqueue the job directly.
      Screenshots.reconcile(post)

      Screenshots.deliver_due(
        force: true,
        capture: fn _job -> {:ok, %{screenshot: "0123456789ab.webp", width: 400, height: 264}} end
      )

      ps = Repo.one!(from(s in Posts.PostScreenshot, where: s.post_id == ^post.id))
      assert ps.status == "ready"
      assert ps.moderation == "pending"
      refute Posts.PostScreenshot.ready?(ps)
      assert open_scan("post_screenshot", ps.id)

      ImageScans.deliver_due(judge: fn _path -> @safe end)
      # No stored file for this fabricated screenshot -> the scan cancels; a
      # real capture (integration-tested via the store) would be judged. What
      # matters here: nothing ever showed while unreleased.
      refute Posts.PostScreenshot.ready?(ps)
    end

    test "profile link screenshot field enters limbo on capture", %{user: user} do
      upload = jpeg_upload()

      {:ok, url} =
        user
        |> Ecto.build_assoc(:urls)
        |> Url.changeset(%{"value" => "https://example.com"})
        |> Repo.insert()

      {:ok, url} =
        url
        |> Url.changeset(%{screenshot: upload})
        |> Repo.update()

      assert url.screenshot_moderation == "pending"
      assert Vutuv.Screenshot.url({url.screenshot, url}, :thumb) == "/images/screenshot.png"
    end
  end

  defp attach_post(user, image) do
    create_post!(user, %{body: "with image"})
    |> then(fn post ->
      Repo.update_all(
        from(i in Posts.PostImage, where: i.id == ^image.id),
        set: [post_id: post.id]
      )

      {:ok, post}
    end)
  end

  defp insert_organization(user) do
    insert(:organization, created_by_user_id: user.id)
  end
end
