defmodule Vutuv.CompanyImageStore do
  @moduledoc """
  On-disk storage for company images (the logo/cover columns and the
  description-editor images) — the `Vutuv.PostImageStore` pattern 1:1. There is
  no public tree: every served byte goes through the authorizing proxy
  (`VutuvWeb.CompanyImageController`), keyed by an unguessable token that is
  also the on-disk directory name.

      <uploads_dir_prefix>/company_images/<token>/thumb.avif /feed.avif /large.avif
      <uploads_dir_prefix>/originals/company_images/<token>/original.<ext>

  Resolution/format/quality of the served versions come from
  `Vutuv.Uploads.Spec` (reusing the `:post_image` spec: AVIF, autorotated then
  metadata-stripped). The extension whitelist (incl. capability-detected HEIC)
  is shared with `Vutuv.PostImageStore`.
  """

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @versions ~w(thumb feed large)

  defdelegate extension_whitelist, to: Vutuv.PostImageStore

  @doc """
  Stores every version of the file at `path` under a fresh `token` directory and
  returns `{:ok, %{width:, height:, content_type:, size_bytes:}}` (dimensions are
  post-rotation) or `{:error, :invalid_file}`.
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
    Spec.write_all(:post_image, rotated, fn spec ->
      Path.join(dir, "#{spec.name}#{Spec.served_ext()}")
    end)
  end

  @doc "Absolute on-disk path of a served version, or `nil` when missing."
  def version_path(token, version) when is_binary(token) and version in @versions do
    avif = Path.join(dir(token), "#{version}#{Spec.served_ext()}")
    if File.exists?(avif), do: avif
  end

  def version_path(_, _), do: nil

  @doc "The production X-Accel-Redirect target for a served version."
  def accel_path(token, version) when is_binary(token) and version in @versions do
    "/internal_company_images/#{token}/#{version}#{Spec.served_ext()}"
  end

  @doc "Removes every stored file of `token`. A no-op when nothing is stored."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    Originals.delete(storage_dir(token))
    :ok
  end

  def delete(_), do: :ok

  defp storage_dir(token) do
    # The token is Base64-URL ([A-Za-z0-9_-]) by construction, but never trust a
    # stored value enough to build paths with separators in it.
    false = String.contains?(token, ["/", ".."])
    Path.join("company_images", token)
  end

  defp dir(token), do: Vutuv.Uploads.disk_dir(storage_dir(token))
end
