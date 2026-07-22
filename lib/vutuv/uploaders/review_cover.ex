defmodule Vutuv.ReviewCover do
  @moduledoc """
  Book-cover storage for post reviews (`Vutuv.Posts.PostReview`): the cover
  bytes fetched from Open Library land here as one served AVIF version plus
  the private original.

      <uploads_dir_prefix>/review_covers/<review.id>/cover-<hash>.avif
      <uploads_dir_prefix>/originals/review_covers/<review.id>/original.jpg

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
  Stores the fetched cover `bytes` for `review`: derives the served AVIF
  (replacing any prior cover) and keeps the original bytes privately.
  Returns `{:ok, "<hash><ext>"}` (for the `cover` column) or
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
        store_original(review, bytes, ext)
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
  Removes every stored file of a review's cover (served + original). A no-op
  when none. The row is the caller's business — post deletion cascades it,
  a moderation rejection clears its columns.
  """
  def delete_files(review) do
    File.rm_rf(disk_dir(review))
    Originals.delete(storage_dir(review))
    :ok
  end

  defp store_original(review, bytes, ext) do
    tmp = Path.join(System.tmp_dir!(), "review-cover-#{review.id}")
    File.write!(tmp, bytes)
    :ok = Originals.store(storage_dir(review), tmp, ext)
    File.rm(tmp)
    :ok
  end

  defp clear_versions(dir) do
    for file <- Path.wildcard(Path.join(dir, "cover-*")), do: File.rm(file)
    :ok
  end

  defp filename(hash), do: "cover-#{hash}#{Spec.served_ext()}"

  defp storage_dir(%{id: id}), do: "review_covers/#{id}"

  defp disk_dir(review), do: Uploads.disk_dir(storage_dir(review))
end
