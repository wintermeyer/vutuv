defmodule Vutuv.ReviewCover do
  @moduledoc """
  Book-cover storage for post reviews (`Vutuv.Posts.PostReview`): the cover
  bytes fetched from Open Library land here as exactly one served AVIF
  version.

      <uploads_dir_prefix>/review_covers/<review.id>/cover-<hash>.avif

  **No private original is kept** — the deliberate exception to the
  `Vutuv.Uploads.Originals` rule that every uploader keeps one. A cover is
  not our picture: it is somebody else's, quoted at thumbnail size beside a
  review, so we hold the one derived version we actually show and nothing
  beyond it. That costs the `Vutuv.Uploads.Regenerator` path (there is
  nothing to re-derive from); after a `Vutuv.Uploads.Spec` change the covers
  are re-fetched by ISBN instead — `Vutuv.Posts.ReviewCovers.refresh_all/1`,
  which also purges the originals stored before v7.122.4.

  Like the screenshots, the served filename is **content-fingerprinted**
  (`<hash>` = first 12 hex chars of the SHA-256 of the fetched bytes), so the
  URL changes whenever the bytes do and responses can be cached immutably.
  The `post_reviews.cover` column stores `<hash><ext>`.

  Unlike the nginx-served screenshots, covers are served through the
  authorizing proxy (`VutuvWeb.ReviewCoverController` — post visibility and
  the AI-moderation verdict are checked per request), so there is no
  quarantine tree here: an unreleased cover simply never leaves the proxy.
  """

  alias Vutuv.Uploads
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @doc """
  Stores the fetched cover `bytes` for `review`: derives the served AVIF,
  replacing any prior cover — and any original a pre-v7.122.4 fetch left
  behind. Returns `{:ok, "<hash><ext>"}` (for the `cover` column) or
  `{:error, reason}` when the bytes don't decode as an image.
  """
  def store_binary(bytes, review, ext \\ ".jpg") when is_binary(bytes) do
    with {:ok, rotated} <- Spec.open_rotated_binary(bytes) do
      hash =
        :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      dir = disk_dir(review)
      File.mkdir_p!(dir)
      clear_versions(dir)

      spec = Spec.version(:review_cover, :cover)

      with :ok <- Spec.write_derived(spec, rotated, Path.join(dir, filename(hash))) do
        purge_original(review)
        {:ok, "#{hash}#{ext}"}
      end
    end
  end

  @doc """
  Absolute on-disk path of the served cover version, or `nil` when missing.
  `version` must match the fingerprinted name the review's `cover` column
  yields (see `version_name/1`) — anything else never resolves.
  """
  def version_path(review, version) do
    if version == version_name(review) do
      path = Path.join(disk_dir(review), version <> Spec.served_ext())
      if File.exists?(path), do: path
    end
  end

  @doc """
  The path nginx would resolve for X-Accel serving. The default install
  serves covers via `send_file` (`:post_image_serving`), like post images.
  """
  def accel_path(review, version) do
    "/internal_review_covers/#{review.id}/#{version}#{Spec.served_ext()}"
  end

  @doc """
  The fingerprinted version segment of a review's stored cover —
  `"cover-<hash>"` — or `nil` when no cover is stored. Both the URL builder
  and the proxy's whitelist derive from this, so they cannot drift.
  """
  def version_name(%{cover: cover}) when is_binary(cover) do
    "cover-" <> Path.rootname(cover)
  end

  def version_name(_review), do: nil

  @doc "Root-relative URL of the served cover, `nil` when none is stored."
  def url(%{id: id} = review) do
    if version = version_name(review) do
      "/review_covers/#{id}/#{version}#{Spec.served_ext()}"
    end
  end

  @doc """
  Removes every stored file of a review's cover. A no-op when none. The row
  is the caller's business — post deletion cascades it, a moderation
  rejection clears its columns.
  """
  def delete_files(review) do
    File.rm_rf(disk_dir(review))
    purge_original(review)
    :ok
  end

  @doc """
  Deletes the private original a pre-v7.122.4 fetch kept for this cover (see
  the module doc). A no-op once none is left, so it is safe to call on every
  store and from `Vutuv.Posts.ReviewCovers.refresh_all/1`.
  """
  def purge_original(review), do: Originals.delete(storage_dir(review))

  defp clear_versions(dir) do
    for file <- Path.wildcard(Path.join(dir, "cover-*")), do: File.rm(file)
    :ok
  end

  defp filename(hash), do: "cover-#{hash}#{Spec.served_ext()}"

  defp storage_dir(%{id: id}), do: "review_covers/#{id}"

  defp disk_dir(review), do: Uploads.disk_dir(storage_dir(review))
end
