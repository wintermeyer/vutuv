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
  cannot be lost by a route moving scope: the routes sit in the plain
  `:browser` scope, where nothing else would ask. Each action takes one of two
  claims, and both resolve to a `%User{}` before any picture moves.

  **The second claim is a signed capability.** A session is how a *browser*
  proves it is a member, and the Mastodon adapter's readers are phone apps whose
  image loader sends neither the cookie nor the bearer token the API call beside
  it used. So both actions take a `VutuvWeb.RemoteMediaToken` as the equivalent
  claim — unforgeable, expiring, and naming exactly the stored file it opens.
  Everything else on the way in is unchanged and re-asked per request, so it
  widens *what* may be seen by nothing; without it, v7.330.0 named every remote
  picture in an API response at a URL no client could fetch.

  The two claims differ in what they carry, because the two pictures differ in
  what they are. An avatar has no audience of its own, so its capability names
  only the account and the file. A **photograph** carries the audience of the
  post it hangs on (issue #1626), so its capability names the **member** the
  adapter rendered it for, and `remote_image_visible?/2` is asked that member's
  own question here like any other reader's.

  Both actions open on `Vutuv.Fediverse.enabled?/0`: switching federation off
  has to close the proxy too, or the pictures it cached go on being served
  after the feature that justified them is gone.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Moderation.Pixelation
  alias Vutuv.RemoteMedia
  alias VutuvWeb.ImageProxy
  alias VutuvWeb.RemoteMediaToken

  # Ordered by what each step costs, the way `avatar/2` below is: an anonymous
  # caller bringing nothing unforgeable is turned away by the signature check
  # before it can spend a query, and which member the capability names can only
  # be settled once the row says which file this picture currently is.
  def post_image(conn, %{"id" => id, "version" => version_file} = params) do
    member? = match?(%User{}, conn.assigns[:current_user])
    token = params[RemoteMediaToken.param()]

    with true <- Fediverse.enabled?(),
         true <- member? or RemoteMediaToken.authentic?(token),
         %RemoteImage{} = image <- Fediverse.get_remote_image(id),
         {shape, version} <- resolve_post_version(image, version_file),
         %User{} = viewer <- reader(conn, token, image),
         true <- Fediverse.remote_image_visible?(image, viewer) do
      serve_post_image(conn, shape, version, image)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # Which file this URL may resolve to — and it is always exactly one (issue
  # #1720):
  #
  #   * a **released** picture answers at its own fingerprinted name, as it
  #     always has;
  #   * an **unreleased** one answers only at its pixelated preview's name, and only while
  #     the pixelated preview stands in.
  #
  # The two states are mutually exclusive, so no URL can serve a picture the
  # gate has not cleared, and a released picture's URL never quietly degrades
  # to a pixelated preview.
  defp resolve_post_version(%RemoteImage{} = image, version_file) do
    cond do
      RemoteImage.released?(image) ->
        versioned(:picture, parse_version(version_file, image.file))

      Pixelation.within_window?(image.inserted_at) ->
        versioned(:pixelated, parse_version(version_file, RemoteMedia.pixelated_name(image.file)))

      true ->
        nil
    end
  end

  defp versioned(_shape, nil), do: nil
  defp versioned(shape, version), do: {shape, version}

  defp serve_post_image(conn, :picture, version, image) do
    serve(conn, version,
      accel: &RemoteMedia.post_image_accel_path(image.id, &1),
      path: &RemoteMedia.post_image_path(image.id, &1, image.file)
    )
  end

  # The version segment was already checked against the one fingerprinted name
  # this picture's preview can have (`resolve_post_version/2`), so the path is
  # resolved from the row alone here. The robots header is this proxy's own —
  # somebody else's photograph must never be indexed as ours, and that holds
  # for 32 cells of it too.
  defp serve_post_image(conn, :pixelated, _version, image) do
    conn
    |> put_resp_header("x-robots-tag", "noindex, noimageindex")
    |> ImageProxy.serve_pixelated(RemoteMedia.post_image_pixelated_path(image.id, image.file))
  end

  defp reader(conn, token, %RemoteImage{} = image) do
    conn.assigns[:current_user] ||
      token
      |> RemoteMediaToken.remote_image_viewer(image.id, image.file)
      |> RemoteMediaToken.holder()
  end

  # An avatar has no per-post audience: it is the picture of an account
  # somebody here follows, shown wherever that account is named. So the check
  # is the gate plus a reader who belongs here — a session, or the capability
  # the API hands its clients.
  #
  # The capability is asked about twice because the two halves of its answer
  # have different costs. Whether we minted it and it is still good is a
  # signature check over the token alone (`authentic?/1`), so it goes ABOVE the
  # lookup and keeps an anonymous caller from spending a query — this route
  # used to refuse them for free and must go on doing so. Which file it opens
  # can only be settled against the row, because a rotated picture has to stop
  # answering, so that half stays below.
  def avatar(conn, %{"id" => id, "version" => version_file} = params) do
    member? = match?(%User{}, conn.assigns[:current_user])
    token = params[RemoteMediaToken.param()]

    with true <- Fediverse.enabled?(),
         true <- member? or RemoteMediaToken.authentic?(token),
         %RemoteAccount{} = account <- Fediverse.get_remote_account(id),
         true <- RemoteAccount.avatar_ready?(account),
         true <- member? or RemoteMediaToken.avatar?(token, account.id, account.avatar),
         version when not is_nil(version) <- parse_version(version_file, account.avatar) do
      serve(conn, version,
        accel: &RemoteMedia.avatar_accel_path(account.id, &1),
        path: &RemoteMedia.avatar_path(account.id, &1, account.avatar)
      )
    else
      _ -> ImageProxy.not_found(conn)
    end
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
