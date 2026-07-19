defmodule VutuvWeb.PendingImageController do
  @moduledoc """
  The owner's preview of their own avatar / cover while it waits in
  AI-moderation limbo (`Vutuv.Moderation.ImageScans`). The derived versions
  live in the quarantine tree, which nginx has no location for — this
  authenticated route (`:settings_pipe`, so `:user` is always the logged-in
  member; there is no way to name another member's image) is the **only**
  path to an unreleased byte, and it only ever serves the requester's own.

  404 for anything else: unknown kind/version, no pending image, files
  already released or deleted. `no-store`, so a rejected image never
  lingers in the browser cache.
  """

  use VutuvWeb, :controller

  alias VutuvWeb.ImageProxy

  # kind -> the served version names (mirrors Vutuv.Uploads.Spec).
  @versions %{"avatar" => ~w(thumb medium), "cover" => ~w(wide)}

  def show(conn, %{"kind" => kind, "version" => version}) do
    user = conn.assigns[:user]

    with true <- version in Map.get(@versions, kind, []),
         path when is_binary(path) <- pending_path(user, kind, version) do
      conn
      |> put_resp_content_type("image/avif")
      |> put_resp_header("cache-control", "private, no-store")
      |> send_file(200, path)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  defp pending_path(user, "avatar", version) do
    if user.avatar_moderation == "pending",
      do: Vutuv.Avatar.pending_preview_path(user, String.to_existing_atom(version))
  end

  defp pending_path(user, "cover", version) do
    if user.cover_moderation == "pending",
      do: Vutuv.Cover.pending_preview_path(user, String.to_existing_atom(version))
  end
end
