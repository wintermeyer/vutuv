defmodule VutuvWeb.RemoteMediaController do
  @moduledoc """
  The authorizing proxy for pictures fetched from other networks (issue #1163):
  a cached post's attachments and a cached account's avatar.

  Everything is re-checked per request, because a picture URL is the one thing
  a reader can hand to somebody else:

    * **who may see it.** A post picture is only served to a member the post
      itself reaches (`Vutuv.Fediverse.remote_post_visible?/2`) — so a
      followers-only post's photograph is no more public than its text.
    * **the AI gate.** An unreleased picture never leaves this proxy, which is
      why there is no quarantine tree for these files.
    * **the exact stored file.** The URL's version segment is the
      content-fingerprinted name, so only the picture currently stored resolves;
      a rotated or rejected one stops answering.

  Denied and unknown are both 404 (`VutuvWeb.ImageProxy`), so the URL space
  says nothing about what exists.

  Every response carries `X-Robots-Tag: noindex, noimageindex`, for the reason
  the review-cover proxy does and more so: this is somebody else's photograph,
  held here because a member follows them. It must never turn up as our picture
  in an image search, and a header is the only thing that prevents it — a
  robots.txt `Disallow` stops the fetch, not the indexing.

  **Login required, checked here.** These pictures exist because a member
  follows their author; none of it is a public surface, and an unguessable URL
  is not an access control — it is a URL, and URLs get shared, logged and
  pasted. The check is in the action rather than in a router pipeline so it
  cannot be lost by a route moving scope, and it is the same `%User{}` gate on
  both actions: the routes sit in the plain `:browser` scope, where nothing
  else would ask.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.RemoteMedia
  alias VutuvWeb.ImageProxy

  def post_image(conn, %{"id" => id, "version" => version_file}) do
    with %User{} = viewer <- viewer(conn),
         %RemoteImage{} = image <- Fediverse.get_remote_image(id),
         true <- RemoteImage.released?(image),
         version when not is_nil(version) <- parse_version(version_file, image.file),
         true <- Fediverse.remote_image_visible?(image, viewer) do
      serve(conn, version,
        accel: &RemoteMedia.post_image_accel_path(image.id, &1),
        path: &RemoteMedia.post_image_path(image.id, &1, image.file)
      )
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # An avatar has no per-post audience: it is the picture of an account
  # somebody here follows, shown wherever that account is named. So the check
  # is the gate plus a signed-in reader.
  def avatar(conn, %{"id" => id, "version" => version_file}) do
    with %User{} <- viewer(conn),
         %RemoteAccount{} = account <- Fediverse.get_remote_account(id),
         true <- RemoteAccount.avatar_ready?(account),
         version when not is_nil(version) <- parse_version(version_file, account.avatar) do
      serve(conn, version,
        accel: &RemoteMedia.avatar_accel_path(account.id, &1),
        path: &RemoteMedia.avatar_path(account.id, &1, account.avatar)
      )
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # A signed-in reader, and only while the installation federates at all:
  # switching federation off has to close the proxy too, or the pictures it
  # cached go on being served after the feature that justified them is gone.
  defp viewer(conn) do
    if Fediverse.enabled?(), do: conn.assigns[:current_user]
  end

  defp serve(conn, version, accel: accel, path: path) do
    conn
    |> put_resp_header("x-robots-tag", "noindex, noimageindex")
    |> ImageProxy.serve(version, accel_path: accel, version_path: path)
  end

  # The whitelist is exactly the fingerprinted name the stored row yields, so a
  # picture that was replaced or rejected stops resolving at its old URL.
  defp parse_version(version_file, stored_file) when is_binary(stored_file) do
    ImageProxy.parse_version(version_file, [Path.rootname(stored_file)])
  end

  defp parse_version(_version_file, _stored_file), do: nil
end
