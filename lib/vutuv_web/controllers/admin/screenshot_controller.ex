defmodule VutuvWeb.Admin.ScreenshotController do
  @moduledoc """
  Streams the picture behind an automatic screenshot-blocklist entry.

  When the page check silences a site, the capture that made it decide is kept
  as evidence — an admin overruling the machine should see what it saw, not a
  sentence about it. The `screenshot_evidence/` tree has no static mount, so
  this authorizing route (admin pipeline) is the only way to it, exactly like
  the moderation evidence stream.
  """

  use VutuvWeb, :controller

  alias Vutuv.ScreenshotBlocklist
  alias VutuvWeb.ControllerHelpers

  def evidence(conn, %{"id" => id}) do
    with entry when not is_nil(entry) <- ScreenshotBlocklist.get_entry(id),
         filename when is_binary(filename) <- entry.evidence_file,
         path = ScreenshotBlocklist.evidence_path(filename),
         true <- File.exists?(path) do
      # The capture is a PNG on the live path and whatever the stored thumb
      # was (AVIF today, pre-AVIF WebP on older rows) when the backfill judged
      # it, so the type comes from the file rather than from an assumption.
      conn
      |> put_resp_content_type(MIME.from_path(path), nil)
      |> send_file(200, path)
    else
      _no_evidence -> ControllerHelpers.render_error(conn, 404)
    end
  end
end
