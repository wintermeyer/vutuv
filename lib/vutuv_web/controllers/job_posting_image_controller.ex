defmodule VutuvWeb.JobPostingImageController do
  @moduledoc """
  The authorizing image proxy for job-posting images — the
  `VutuvWeb.PostImageController` pattern 1:1. Every byte is served through here,
  so a posting's visibility (`Vutuv.Jobs.visible_to?/2`) also guards its images.
  Pending images (posting not yet saved) are visible to their uploader alone;
  denied and unknown tokens are both 404 so the proxy never leaks existence.
  """

  use VutuvWeb, :controller

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPostingImage

  @cache_control "private, max-age=31536000, immutable"

  def show(conn, %{"token" => token, "version" => version_file}) do
    with version when not is_nil(version) <- parse_version(version_file),
         image when not is_nil(image) <- Jobs.get_image_by_token(token),
         true <- Jobs.image_visible_to?(image, conn.assigns[:current_user]) do
      serve(conn, image, version)
    else
      _ -> not_found(conn)
    end
  end

  defp parse_version(version_file) do
    case String.split(version_file, ".") do
      [version, ext] when ext in ["avif", "webp"] ->
        if version in JobPostingImage.versions(), do: version

      _ ->
        nil
    end
  end

  defp serve(conn, image, version) do
    conn = put_resp_header(conn, "cache-control", @cache_control)

    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        accel_path = Vutuv.JobPostingImageStore.accel_path(image, version)

        conn
        |> put_resp_content_type(MIME.from_path(accel_path))
        |> put_resp_header("x-accel-redirect", accel_path)
        |> send_resp(200, "")

      _send_file ->
        case Vutuv.JobPostingImageStore.version_path(image, version) do
          nil ->
            not_found(conn)

          path ->
            conn
            |> put_resp_content_type(MIME.from_path(path))
            |> send_file(200, path)
        end
    end
  end

  defp not_found(conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
