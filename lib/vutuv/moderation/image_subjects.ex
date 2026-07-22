defmodule Vutuv.Moderation.ImageSubjects do
  @moduledoc """
  The per-kind plumbing behind the image-moderation queue
  (`Vutuv.Moderation.ImageScans`): for each scannable asset kind, where its
  bytes live (`source/1` — always the private **original**, uncropped, so a
  crop can never hide part of the picture from the model), how a safe verdict
  releases it (`apply_approved/1`) and how an unsafe verdict deletes it
  (`apply_rejected/1`).

  Every state flip is an atomic, guarded `update_all`: the WHERE re-checks
  the asset still holds the scanned bytes (fingerprint columns for assets
  that change in place; gallery rows are immutable), so a verdict that lost a
  race against a re-upload returns `:stale` and touches nothing.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReview
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.Url
  alias Vutuv.QualificationDocument
  alias Vutuv.Repo
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Originals

  # The avatar/cover twins differ only in their column names + uploader module.
  @profile_images %{
    "avatar" => %{
      file: :avatar,
      fingerprint: :avatar_fingerprint,
      crop: :avatar_crop,
      moderation: :avatar_moderation,
      module: Vutuv.Avatar,
      prefix: "avatars"
    },
    "cover" => %{
      file: :cover_photo,
      fingerprint: :cover_fingerprint,
      crop: :cover_crop,
      moderation: :cover_moderation,
      module: Vutuv.Cover,
      prefix: "covers"
    }
  }

  @gallery_images %{
    "post_image" => %{schema: PostImage, store: Vutuv.PostImageStore, prefix: "post_images"},
    "job_posting_image" => %{
      schema: JobPostingImage,
      store: Vutuv.JobPostingImageStore,
      prefix: "job_posting_images"
    },
    "organization_image" => %{
      schema: OrganizationImage,
      store: Vutuv.OrganizationImageStore,
      prefix: "organization_images"
    }
  }

  ## Source resolution

  @doc """
  The on-disk file the model should judge: the private original when kept,
  else the stored derived version. `:gone` when the subject vanished or no
  longer holds the scanned bytes (the scan is then canceled).
  """
  def source(%ImageScan{kind: kind} = scan) when is_map_key(@profile_images, kind) do
    config = @profile_images[kind]

    with %User{} = user <- Repo.get(User, scan.subject_id),
         true <- Map.get(user, config.file) != nil,
         true <- Map.get(user, config.fingerprint) == scan.fingerprint do
      # Fresh uploads have an original (and quarantine files while pending);
      # the served-file fallback covers legacy rows from before originals
      # were kept, so the backfill can judge them too.
      first_existing([
        Originals.path("#{config.prefix}/#{user.id}"),
        quarantine_file("#{config.prefix}/#{user.id}"),
        largest_served_file("#{config.prefix}/#{user.id}")
      ])
    else
      _ -> :gone
    end
  end

  def source(%ImageScan{kind: kind} = scan) when is_map_key(@gallery_images, kind) do
    config = @gallery_images[kind]

    case Repo.get(config.schema, scan.subject_id) do
      nil ->
        :gone

      image ->
        first_existing([
          Originals.path("#{config.prefix}/#{image.token}"),
          config.store.version_path(image_path_arg(kind, image), "large")
        ])
    end
  end

  def source(%ImageScan{kind: "url_screenshot"} = scan) do
    with %Url{} = url <- Repo.get(Url, scan.subject_id),
         true <- url.screenshot != nil and url.screenshot == scan.fingerprint do
      screenshot_source(url.id)
    else
      _ -> :gone
    end
  end

  def source(%ImageScan{kind: "review_cover"} = scan) do
    with %PostReview{} = review <- Repo.get(PostReview, scan.subject_id),
         true <- review.cover != nil and review.cover == scan.fingerprint do
      first_existing([
        Originals.path("review_covers/#{review.id}"),
        largest_served_file("review_covers/#{review.id}")
      ])
    else
      _ -> :gone
    end
  end

  # The qualification proof document: the upload-time rendered PDF page when
  # one exists (the vision model cannot decode a PDF), else the verbatim
  # original image. Fingerprint-guarded like the other in-place assets.
  def source(%ImageScan{kind: "qualification_document"} = scan) do
    with %Qualification{} = qualification <- Repo.get(Qualification, scan.subject_id),
         true <-
           qualification.document_fingerprint != nil and
             qualification.document_fingerprint == scan.fingerprint,
         path when is_binary(path) <- QualificationDocument.scan_source_path(qualification.id) do
      {:ok, path}
    else
      _ -> :gone
    end
  end

  def source(%ImageScan{kind: "post_screenshot"} = scan) do
    with %PostScreenshot{} = ps <- Repo.get(PostScreenshot, scan.subject_id),
         true <- ps.screenshot != nil and ps.screenshot == scan.fingerprint do
      screenshot_source(ps.id)
    else
      _ -> :gone
    end
  end

  # The organization store's version_path takes the bare token, the other two
  # take the struct.
  defp image_path_arg("organization_image", image), do: image.token
  defp image_path_arg(_kind, image), do: image

  defp screenshot_source(scope_id) do
    first_existing([
      Originals.path("screenshots/#{scope_id}"),
      quarantine_file("screenshots/#{scope_id}"),
      largest_served_file("screenshots/#{scope_id}")
    ])
  end

  defp quarantine_file(storage_dir) do
    storage_dir
    |> Uploads.quarantine_dir()
    |> Path.join("*")
    |> Path.wildcard()
    |> List.first()
  end

  # The biggest served version — the best pixels available when no original
  # was kept (pre-originals legacy rows hit by the backfill).
  defp largest_served_file(storage_dir) do
    storage_dir
    |> Uploads.disk_dir()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort_by(&File.stat!(&1).size, :desc)
    |> List.first()
  end

  defp first_existing(candidates) do
    case Enum.find(candidates, &(&1 && File.exists?(&1))) do
      nil -> :gone
      path -> {:ok, path}
    end
  end

  ## Applying verdicts

  @doc """
  Releases the scanned image to the world: flips the asset's moderation state
  (guarded on the scanned bytes), moves nginx-served files out of quarantine
  and pings open pages. `:stale` when the asset changed under the verdict.
  """
  def apply_approved(%ImageScan{kind: kind} = scan) when is_map_key(@profile_images, kind) do
    config = @profile_images[kind]

    flipped =
      from(u in User,
        where:
          u.id == ^scan.subject_id and
            field(u, ^config.fingerprint) == ^scan.fingerprint and
            field(u, ^config.moderation) == "pending"
      )
      |> Repo.update_all(set: [{config.moderation, "approved"}])

    case flipped do
      {1, _} ->
        config.module.promote_from_quarantine(Repo.get!(User, scan.subject_id))
        broadcast(scan, :approved)
        :ok

      _ ->
        :stale
    end
  end

  def apply_approved(%ImageScan{kind: kind} = scan) when is_map_key(@gallery_images, kind) do
    config = @gallery_images[kind]

    flipped =
      from(i in config.schema, where: i.id == ^scan.subject_id and i.moderation == "pending")
      |> Repo.update_all(set: [moderation: "approved"])

    case flipped do
      {1, _} ->
        # A released organization logo also flips the `organizations.logo`
        # pointer (the old logo kept showing during limbo).
        if kind == "organization_image" do
          {:ok, _organization} =
            Vutuv.Organizations.release_logo(Repo.get!(OrganizationImage, scan.subject_id))
        end

        broadcast(scan, :approved)
        :ok

      _ ->
        :stale
    end
  end

  def apply_approved(%ImageScan{kind: "url_screenshot"} = scan) do
    flipped =
      from(u in Url,
        where:
          u.id == ^scan.subject_id and u.screenshot == ^scan.fingerprint and
            u.screenshot_moderation == "pending"
      )
      |> Repo.update_all(set: [screenshot_moderation: "approved"])

    case flipped do
      {1, _} ->
        Vutuv.Screenshot.promote_from_quarantine(Repo.get!(Url, scan.subject_id))
        :ok

      _ ->
        :stale
    end
  end

  def apply_approved(%ImageScan{kind: "post_screenshot"} = scan) do
    flipped =
      from(ps in PostScreenshot,
        where:
          ps.id == ^scan.subject_id and ps.screenshot == ^scan.fingerprint and
            ps.moderation == "pending"
      )
      |> Repo.update_all(set: [moderation: "approved"])

    case flipped do
      {1, _} ->
        ps = Repo.get!(PostScreenshot, scan.subject_id)
        Vutuv.Screenshot.promote_from_quarantine(ps)
        # The card upgrade was deliberately held back at capture time; the
        # screenshot is only announced once it is released.
        Vutuv.Posts.broadcast_screenshot_ready(ps.post_id)
        :ok

      _ ->
        :stale
    end
  end

  def apply_approved(%ImageScan{kind: "qualification_document"} = scan) do
    flipped =
      from(q in Qualification,
        where:
          q.id == ^scan.subject_id and q.document_fingerprint == ^scan.fingerprint and
            q.document_moderation == "pending"
      )
      |> Repo.update_all(set: [document_moderation: "approved"])

    case flipped do
      {1, _} ->
        # No quarantine move: the files are served through the authorizing
        # proxy, which checks this state (the review-cover pattern).
        broadcast(scan, :approved)
        :ok

      _ ->
        :stale
    end
  end

  def apply_approved(%ImageScan{kind: "review_cover"} = scan) do
    flipped =
      from(r in PostReview,
        where:
          r.id == ^scan.subject_id and r.cover == ^scan.fingerprint and
            r.cover_moderation == "pending"
      )
      |> Repo.update_all(set: [cover_moderation: "approved"])

    case flipped do
      {1, _} ->
        review = Repo.get!(PostReview, scan.subject_id)
        # The card upgrade was held back at fetch time; the cover is only
        # announced once it is released (no quarantine move — covers are
        # served through the authorizing proxy, which checks this state).
        Vutuv.Posts.broadcast_review_cover_ready(review.post_id)
        :ok

      _ ->
        :stale
    end
  end

  @doc """
  Deletes the rejected image on the spot: files (served, quarantined and the
  private original — nothing unsafe stays at rest) and the asset's
  reference to them. `:stale` when the asset changed under the verdict.
  """
  def apply_rejected(%ImageScan{kind: kind} = scan) when is_map_key(@profile_images, kind) do
    config = @profile_images[kind]

    cleared =
      from(u in User,
        where: u.id == ^scan.subject_id and field(u, ^config.fingerprint) == ^scan.fingerprint
      )
      |> Repo.update_all(set: clear_profile_columns(config))

    case cleared do
      {1, _} ->
        config.module.delete(%User{id: scan.subject_id})
        broadcast(scan, :rejected)
        :ok

      _ ->
        :stale
    end
  end

  def apply_rejected(%ImageScan{kind: kind} = scan) when is_map_key(@gallery_images, kind) do
    config = @gallery_images[kind]

    case Repo.get(config.schema, scan.subject_id) do
      nil ->
        :stale

      image ->
        config.store.delete(image.token)
        Repo.delete(image, allow_stale: true)
        clear_gallery_references(kind, image)
        broadcast(scan, :rejected)
        :ok
    end
  end

  def apply_rejected(%ImageScan{kind: "url_screenshot"} = scan) do
    cleared =
      from(u in Url, where: u.id == ^scan.subject_id and u.screenshot == ^scan.fingerprint)
      |> Repo.update_all(set: [screenshot: nil, screenshot_moderation: nil])

    case cleared do
      {1, _} ->
        Vutuv.Screenshot.delete(%Url{id: scan.subject_id})
        :ok

      _ ->
        :stale
    end
  end

  def apply_rejected(%ImageScan{kind: "post_screenshot"} = scan) do
    cleared =
      from(ps in PostScreenshot,
        where: ps.id == ^scan.subject_id and ps.screenshot == ^scan.fingerprint
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          moderation: "rejected",
          screenshot: nil,
          last_error: "moderation_rejected"
        ]
      )

    case cleared do
      {1, _} ->
        Vutuv.Screenshot.delete(%PostScreenshot{id: scan.subject_id})
        :ok

      _ ->
        :stale
    end
  end

  def apply_rejected(%ImageScan{kind: "qualification_document"} = scan) do
    cleared =
      from(q in Qualification,
        where: q.id == ^scan.subject_id and q.document_fingerprint == ^scan.fingerprint
      )
      |> Repo.update_all(set: clear_document_columns())

    case cleared do
      {1, _} ->
        QualificationDocument.delete(scan.subject_id)
        broadcast(scan, :rejected)
        :ok

      _ ->
        :stale
    end
  end

  def apply_rejected(%ImageScan{kind: "review_cover"} = scan) do
    cleared =
      from(r in PostReview, where: r.id == ^scan.subject_id and r.cover == ^scan.fingerprint)
      |> Repo.update_all(set: [cover: nil, cover_status: "failed", cover_moderation: nil])

    case cleared do
      {1, _} ->
        Vutuv.ReviewCover.delete_files(%PostReview{id: scan.subject_id})
        :ok

      _ ->
        :stale
    end
  end

  # An organization's `logo` column points at its image token; a rejected logo
  # must not leave a dangling pointer behind.
  defp clear_gallery_references("organization_image", image) do
    from(o in Organization, where: o.logo == ^image.token)
    |> Repo.update_all(set: [logo: nil])

    :ok
  end

  defp clear_gallery_references(_kind, _image), do: :ok

  @doc """
  Best-effort cleanup after a canceled scan (the subject vanished before the
  verdict): an asset still pointing at the scanned-but-now-missing bytes is
  cleared, so no row keeps referencing files that are gone (no
  Karteileichen). All guarded like the verdict paths.
  """
  def cleanup_canceled(%ImageScan{kind: kind} = scan) when is_map_key(@profile_images, kind) do
    config = @profile_images[kind]

    from(u in User,
      where:
        u.id == ^scan.subject_id and
          field(u, ^config.fingerprint) == ^scan.fingerprint and
          field(u, ^config.moderation) == "pending"
    )
    |> Repo.update_all(set: clear_profile_columns(config))

    :ok
  end

  def cleanup_canceled(%ImageScan{}), do: :ok

  # The four profile-image columns (file, fingerprint, crop, moderation) reset to
  # nil when a scan rejects the image or cancels a pending one.
  defp clear_profile_columns(config),
    do: [
      {config.file, nil},
      {config.fingerprint, nil},
      {config.crop, nil},
      {config.moderation, nil}
    ]

  # Every document column resets when a scan rejects the proof document; the
  # list lives on the schema so no clearing path can miss a column.
  defp clear_document_columns, do: Qualification.document_reset_fields()

  ## Drift repair source

  @doc """
  Every asset stuck in `pending` with no open scan, as
  `{kind, subject_id, owner_user_id, fingerprint}` — what
  `Vutuv.Moderation.ImageScans.repair_drift/0` re-enqueues.
  """
  def stranded_pending do
    profile_stranded("avatar") ++
      profile_stranded("cover") ++
      gallery_stranded("post_image") ++
      gallery_stranded("job_posting_image") ++
      gallery_stranded("organization_image") ++
      url_screenshot_stranded() ++
      post_screenshot_stranded() ++
      review_cover_stranded() ++
      qualification_document_stranded()
  end

  defp open_scan_exists(kind) do
    from(s in ImageScan,
      where:
        s.kind == ^kind and s.subject_id == parent_as(:subject).id and
          s.status in ~w(pending scanning)
    )
  end

  defp profile_stranded(kind) do
    config = @profile_images[kind]

    from(u in User,
      as: :subject,
      where: field(u, ^config.moderation) == "pending",
      where: not exists(open_scan_exists(kind)),
      select: {u.id, field(u, ^config.fingerprint)}
    )
    |> Repo.all()
    |> Enum.map(fn {id, fingerprint} -> {kind, id, id, fingerprint} end)
  end

  defp gallery_stranded(kind) do
    config = @gallery_images[kind]

    from(i in config.schema,
      as: :subject,
      where: i.moderation == "pending",
      where: not exists(open_scan_exists(kind)),
      select: {i.id, i.user_id}
    )
    |> Repo.all()
    |> Enum.map(fn {id, owner_id} -> {kind, id, owner_id, nil} end)
  end

  defp url_screenshot_stranded do
    from(u in Url,
      as: :subject,
      where: u.screenshot_moderation == "pending",
      where: not exists(open_scan_exists("url_screenshot")),
      select: {u.id, u.user_id, u.screenshot}
    )
    |> Repo.all()
    |> Enum.map(fn {id, owner_id, fingerprint} ->
      {"url_screenshot", id, owner_id, fingerprint}
    end)
  end

  defp post_screenshot_stranded do
    from(ps in PostScreenshot,
      as: :subject,
      join: p in assoc(ps, :post),
      where: ps.moderation == "pending",
      where: not exists(open_scan_exists("post_screenshot")),
      select: {ps.id, p.user_id, ps.screenshot}
    )
    |> Repo.all()
    |> Enum.map(fn {id, owner_id, fingerprint} ->
      {"post_screenshot", id, owner_id, fingerprint}
    end)
  end

  defp review_cover_stranded do
    from(r in PostReview,
      as: :subject,
      join: p in assoc(r, :post),
      where: r.cover_moderation == "pending",
      where: not exists(open_scan_exists("review_cover")),
      select: {r.id, p.user_id, r.cover}
    )
    |> Repo.all()
    |> Enum.map(fn {id, owner_id, fingerprint} ->
      {"review_cover", id, owner_id, fingerprint}
    end)
  end

  defp qualification_document_stranded do
    from(q in Qualification,
      as: :subject,
      where: q.document_moderation == "pending",
      where: not exists(open_scan_exists("qualification_document")),
      select: {q.id, q.user_id, q.document_fingerprint}
    )
    |> Repo.all()
    |> Enum.map(fn {id, owner_id, fingerprint} ->
      {"qualification_document", id, owner_id, fingerprint}
    end)
  end

  # Live pages re-render the affected image (or drop the limbo pill) with no
  # reload; dead pages catch up on the next request.
  defp broadcast(%ImageScan{} = scan, verdict) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      "user:#{scan.owner_user_id}",
      {:image_moderation, scan.kind, scan.subject_id, verdict}
    )
  end
end
