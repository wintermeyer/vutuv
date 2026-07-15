defmodule VutuvWeb.OrganizationImageController do
  @moduledoc """
  The authorizing organization-image proxy (issue #929): every logo / description
  image byte is served through here, so a page's visibility guards its images
  too (a pending or frozen organization's logo is owner/admin-only, and flips public
  the moment the page goes active). Serving mechanics shared via
  `VutuvWeb.ImageProxy` (and the `:post_image_serving` mode, so an organization
  image streams the same way post images do). Denied and unknown tokens are
  both 404.
  """

  use VutuvWeb, :controller

  alias Vutuv.OrganizationImageStore
  alias Vutuv.Organizations
  alias VutuvWeb.ImageProxy

  def show(conn, %{"token" => token, "version" => version_file}) do
    with version when not is_nil(version) <-
           ImageProxy.parse_version(version_file, OrganizationImageStore.versions()),
         image when not is_nil(image) <- Organizations.get_image_by_token(token),
         true <- Organizations.image_visible_to?(image, conn.assigns[:current_user]) do
      ImageProxy.serve(conn, version,
        accel_path: &OrganizationImageStore.accel_path(token, &1),
        version_path: &OrganizationImageStore.version_path(token, &1)
      )
    else
      _ -> ImageProxy.not_found(conn)
    end
  end
end
