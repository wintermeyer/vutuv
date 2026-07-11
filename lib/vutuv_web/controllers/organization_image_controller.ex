defmodule VutuvWeb.OrganizationImageController do
  @moduledoc """
  The authorizing organization-image proxy (issue #929): every logo / description
  image byte is served through here, so a page's visibility guards its images
  too (a pending or frozen organization's logo is owner/admin-only, and flips public
  the moment the page goes active). Mirrors `VutuvWeb.PostImageController`:
  X-Accel-Redirect in production, `send_file` in dev/test. Denied and unknown
  tokens are both 404.
  """

  use VutuvWeb, :controller

  alias Vutuv.OrganizationImageStore
  alias Vutuv.Organizations

  @cache_control "private, max-age=31536000, immutable"

  def show(conn, %{"token" => token, "version" => version_file}) do
    with version when not is_nil(version) <- parse_version(version_file),
         image when not is_nil(image) <- Organizations.get_image_by_token(token),
         true <- Organizations.image_visible_to?(image, conn.assigns[:current_user]) do
      serve(conn, token, version)
    else
      _ -> not_found(conn)
    end
  end

  defp parse_version(version_file) do
    case String.split(version_file, ".") do
      [version, ext] when ext in ["avif", "webp"] ->
        if version in ~w(thumb feed large), do: version

      _ ->
        nil
    end
  end

  # Reuses the post-image serving mode (:post_image_serving), so an organization image
  # streams the same way (send_file in prod today, per the post-image topology).
  defp serve(conn, token, version) do
    conn = put_resp_header(conn, "cache-control", @cache_control)

    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        accel_path = OrganizationImageStore.accel_path(token, version)

        conn
        |> put_resp_content_type(MIME.from_path(accel_path))
        |> put_resp_header("x-accel-redirect", accel_path)
        |> send_resp(200, "")

      _send_file ->
        case OrganizationImageStore.version_path(token, version) do
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
