defmodule Vutuv.JobPostingImageStore do
  @moduledoc """
  On-disk storage for job-posting images — the `Vutuv.PostImageStore` pattern
  1:1. Every served byte goes through the authorizing proxy
  (`VutuvWeb.JobPostingImageController`); derived AVIF versions live in one
  directory per image keyed by its URL token, the uploaded original in the
  shared private `originals/` tree:

      <uploads_dir_prefix>/job_posting_images/<token>/thumb.avif
                                                      /feed.avif
                                                      /large.avif
      <uploads_dir_prefix>/originals/job_posting_images/<token>/original.<ext>

  The accepted extensions and HEIC capability detection are shared with
  `Vutuv.PostImageStore` (one probe for the whole app).
  """

  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @doc "Accepted upload extensions (shared with post images, HEIC-capability-gated)."
  defdelegate extension_whitelist, to: Vutuv.PostImageStore

  @doc """
  Stores every version of the file at `path` (named `filename`) under a fresh
  `token` directory, returning `{:ok, %{width:, height:, content_type:,
  size_bytes:}}` (post-rotation dimensions) or `{:error, :invalid_file}`.
  """
  def store(path, filename, token) do
    ext = filename |> Path.extname() |> String.downcase()

    if ext in extension_whitelist() do
      dir = dir(token)
      File.mkdir_p!(dir)

      case write_versions(path, ext, dir, token) do
        {:ok, meta} ->
          {:ok, Map.merge(meta, %{content_type: MIME.from_path(filename)})}

        {:error, _reason} ->
          File.rm_rf(dir)
          {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  defp write_versions(path, ext, dir, token) do
    with {:ok, rotated} <- Spec.open_rotated(path),
         :ok <- write_derived_versions(rotated, dir) do
      :ok = Originals.store(storage_dir(token), path, ext)

      {:ok,
       %{
         width: Image.width(rotated),
         height: Image.height(rotated),
         size_bytes: File.stat!(path).size
       }}
    end
  end

  defp write_derived_versions(rotated, dir) do
    Spec.write_all(:job_posting_image, rotated, fn spec ->
      Path.join(dir, "#{spec.name}#{Spec.served_ext()}")
    end)
  end

  @doc "Re-derives every served version from the kept original (for the Regenerator)."
  def regenerate(%JobPostingImage{token: token}, opts \\ []) do
    dir = dir(token)

    Vutuv.Uploads.regenerate_from_original(storage_dir(token), dir,
      canonical: canonical_filenames(),
      stale_glob: "*",
      legacy_candidates: [Path.join(dir, "original.*")],
      derive: &write_derived_versions(&1, dir),
      opts: opts
    )
  end

  defp canonical_filenames do
    for spec <- Spec.versions(:job_posting_image), do: "#{spec.name}#{Spec.served_ext()}"
  end

  @doc "Absolute on-disk path of a served version, or nil when missing."
  def version_path(%JobPostingImage{token: token}, version) do
    if filename = version_filename(token, version) do
      Path.join(dir(token), filename)
    end
  end

  @doc "The production X-Accel-Redirect target for a served version."
  def accel_path(%JobPostingImage{token: token}, version) when is_binary(version) do
    filename = version_filename(token, version) || "#{version}#{Spec.served_ext()}"
    "/internal_job_posting_images/#{token}/#{filename}"
  end

  defp version_filename(token, version) do
    if version in JobPostingImage.versions() do
      dir = dir(token)
      avif = "#{version}#{Spec.served_ext()}"
      webp = "#{version}.webp"

      cond do
        File.exists?(Path.join(dir, avif)) -> avif
        File.exists?(Path.join(dir, webp)) -> webp
        true -> nil
      end
    end
  end

  @doc "Removes every stored file of `token`. A no-op when nothing is stored."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    Originals.delete(storage_dir(token))
    :ok
  end

  defp storage_dir(token) do
    false = String.contains?(token, ["/", ".."])
    Path.join("job_posting_images", token)
  end

  defp dir(token), do: Vutuv.Uploads.disk_dir(storage_dir(token))
end
