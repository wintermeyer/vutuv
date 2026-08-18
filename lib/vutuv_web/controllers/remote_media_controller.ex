defmodule VutuvWeb.RemoteMediaController do
  @moduledoc """
  The authorizing proxy for pictures fetched from other networks (issue #1163):
  a cached post's attachments and a cached account's avatar.

  Everything is re-checked per request, because a picture URL is the one thing
  a reader can hand to somebody else:

    * **who may see it.** A post picture is served to exactly the members who
      may read the post itself (`Vutuv.Fediverse.remote_image_visible?/2`) — so
      a followers-only post's photograph is no more public than its text, and
      an open one's is no *less* readable than its text either, however the
      reader met it (their own follow, a boost, a member's repost, the account
      page).
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

  **Or a signed capability, on the avatar.** A session is how a *browser*
  proves it is a member, and the Mastodon adapter's readers are phone apps
  whose image loader sends neither the cookie nor the bearer token the API call
  beside it used. So the avatar action takes a `VutuvWeb.RemoteMediaToken` as
  the equivalent claim — unforgeable, expiring, and naming exactly the account
  and stored file it opens. Everything else on the way in is unchanged and
  re-asked per request, so it widens what may be seen by nothing; without it,
  v7.330.0 named every remote picture in an API response at a URL no client
  could fetch. `post_image/2` has no such door because the adapter names no
  remote attachment — see `VutuvWeb.RemoteMediaToken`.

  Both actions open on `Vutuv.Fediverse.enabled?/0`: switching federation off
  has to close the proxy too, or the pictures it cached go on being served
  after the feature that justified them is gone.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.RemoteMedia
  alias VutuvWeb.ImageProxy
  alias VutuvWeb.RemoteMediaToken

  def post_image(conn, %{"id" => id, "version" => version_file}) do
    with true <- Fediverse.enabled?(),
         %User{} = viewer <- conn.assigns[:current_user],
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
  # is the gate plus a reader who belongs here — a session, or the capability
  # the API hands its clients.
  #
  # `signed_in?/1` is asked twice on purpose. The second time is the real
  # check, and it needs the row, because a capability names the file the row
  # currently holds. The first is a pre-filter: this route answers without a
  # session, and a caller who brings neither claim must not be able to make us
  # read the database at all.
  def avatar(conn, %{"id" => id, "version" => version_file} = params) do
    token = params[RemoteMediaToken.param()]

    with true <- Fediverse.enabled?(),
         true <- signed_in?(conn) or is_binary(token),
         %RemoteAccount{} = account <- Fediverse.get_remote_account(id),
         true <- RemoteAccount.avatar_ready?(account),
         true <- signed_in?(conn) or RemoteMediaToken.avatar?(token, account.id, account.avatar),
         version when not is_nil(version) <- parse_version(version_file, account.avatar) do
      serve(conn, version,
        accel: &RemoteMedia.avatar_accel_path(account.id, &1),
        path: &RemoteMedia.avatar_path(account.id, &1, account.avatar)
      )
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  defp signed_in?(conn), do: match?(%User{}, conn.assigns[:current_user])

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
