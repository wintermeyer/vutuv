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

  alias Vutuv.Uploads.Spec
  alias VutuvWeb.ImageProxy

  # kind -> the served version names, read from `Vutuv.Uploads.Spec` rather
  # than typed out again: a hand-kept copy silently 404s the owner's preview of
  # a version added there later (the avatar's `:large` was exactly that case).
  @versions %{
    "avatar" => Enum.map(Spec.versions(:avatar), &to_string(&1.name)),
    "cover" => Enum.map(Spec.versions(:cover), &to_string(&1.name))
  }

  def show(conn, %{"kind" => kind, "version" => version}) do
    user = conn.assigns[:user]

    with true <- version in Map.get(@versions, kind, []),
         path when is_binary(path) <- pending_path(user, kind, version) do
      conn
      |> put_resp_content_type("image/avif", nil)
      |> put_resp_header("cache-control", "private, no-store")
      |> send_file(200, path)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # The picture's row is read once and handed on as the preload the uploader
  # would otherwise look up again (issue #2027).
  defp pending_path(user, kind, version) do
    case Vutuv.Images.member_image(user, kind) do
      %Vutuv.Images.Image{moderation: "pending"} = image ->
        user
        |> Map.put(Vutuv.Images.member_columns(kind).assoc, image)
        |> preview_path(kind, String.to_existing_atom(version))

      _not_pending ->
        nil
    end
  end

  defp preview_path(user, "avatar", version), do: Vutuv.Avatar.pending_preview_path(user, version)
  defp preview_path(user, "cover", version), do: Vutuv.Cover.pending_preview_path(user, version)
end
