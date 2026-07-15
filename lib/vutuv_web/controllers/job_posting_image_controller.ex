defmodule VutuvWeb.JobPostingImageController do
  @moduledoc """
  The authorizing image proxy for job-posting images — the
  `VutuvWeb.PostImageController` pattern 1:1 (serving mechanics shared via
  `VutuvWeb.ImageProxy`). Every byte is served through here, so a posting's
  visibility (`Vutuv.Jobs.visible_to?/2`) also guards its images. Pending
  images (posting not yet saved) are visible to their uploader alone; denied
  and unknown tokens are both 404 so the proxy never leaks existence.
  """

  use VutuvWeb, :controller

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPostingImage
  alias VutuvWeb.ImageProxy

  def show(conn, %{"token" => token, "version" => version_file}) do
    with version when not is_nil(version) <-
           ImageProxy.parse_version(version_file, JobPostingImage.versions()),
         image when not is_nil(image) <- Jobs.get_image_by_token(token),
         true <- Jobs.image_visible_to?(image, conn.assigns[:current_user]) do
      ImageProxy.serve(conn, version,
        accel_path: &Vutuv.JobPostingImageStore.accel_path(image, &1),
        version_path: &Vutuv.JobPostingImageStore.version_path(image, &1)
      )
    else
      _ -> ImageProxy.not_found(conn)
    end
  end
end
