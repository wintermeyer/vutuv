defmodule Vutuv.Moderation.ContentUrl do
  @moduledoc """
  Which piece of reportable content one of **our own** URLs names (issue #2009).

  The public notice form at `/system/report` starts with a pasted address, and
  a rights holder pastes whatever their browser, their mail client or a share
  button handed them: the `www.` alias, a trailing slash, an appended
  `?utm_source=`, a fragment, a shouted host, plain `http`, a dev port. Every
  one of those names the same page and every one of them misses a whole-string
  prefix match on `Endpoint.url()`, so the host question is asked once, by
  `Vutuv.Fediverse.local_path/1`, which parses the URI, strips a leading `www.`
  on both sides and hands back the path segments with the empties dropped (the
  query and the fragment are not in `path` at all).

  Two rules the shapes below follow.

  **A record is resolved by the id in the path, never by the handle beside
  it.** A handle goes stale the moment its owner renames, and landing on the
  right post beats a dead end.

  **Only content an anonymous visitor can already see resolves.** The form is
  unauthenticated, so answering "that URL exists" for anything else would make
  it an oracle for frozen, deleted, restricted and members-only content —
  something the same visitor cannot learn by fetching the URL. Everything else
  comes back `{:error, :not_found}`, which is the same answer a typo gets — one
  exception, `{:error, :not_reportable}` for a page of the site itself, is
  decided by the router alone and reads no row, so it can tell nobody anything
  (issue #2068).
  """

  import Ecto.Query

  alias Phoenix.Router, as: PhoenixRouter
  alias Vutuv.Accounts.ReservedSlugs
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Jobs
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.PressKit
  alias Vutuv.Repo
  alias Vutuv.UUIDv7
  alias Vutuv.Videos
  alias VutuvWeb.Endpoint
  alias VutuvWeb.Router

  @reserved ReservedSlugs.list()

  @doc """
  Resolves `url` to the content row it names.

  `{:ok, content}` for a reportable, publicly visible row, and three misses a
  notifier has to be able to tell apart (issue #2068):

  * `{:error, :foreign_host}` — the address belongs to another server, so we
    can only say we do not host it.
  * `{:error, :not_reportable}` — one of **our own pages**, which is a correct
    address carrying nobody's content.
  * `{:error, :not_found}` — everything else, and only here is "we could not
    find it" true.
  """
  def resolve(url) when is_binary(url) do
    case url |> String.trim() |> with_scheme() |> Fediverse.local_path() do
      nil -> {:error, :foreign_host}
      segments -> found(from_segments(segments), segments)
    end
  end

  def resolve(_url), do: {:error, :not_found}

  # A scheme-less paste is one more spelling of the same page, and the browser
  # bar is not the only place an address is copied from. `URI.parse/1` cannot
  # be asked whether one is missing — it reads `vutuv.de/wintermeyer` as the
  # scheme `vutuv.de` with no host at all — so the test is on the two schemes
  # our own URLs ever carry.
  defp with_scheme(url) do
    if url =~ ~r{^https?://}i, do: url, else: "https://" <> url
  end

  # `nil` is "I know this shape and there is nothing there" — a typo, a deleted
  # post, a hidden one — and stays the miss. `:no_content_shape` is "this is
  # not an address content lives at", which is the only case allowed to ask
  # whether the site itself has a page there.
  defp found(:no_content_shape, segments), do: site_page(segments)
  defp found(nil, _segments), do: {:error, :not_found}
  defp found(content, _segments), do: {:ok, content}

  # The address names no member's and no page's content, so the last question
  # is whether it is a page of the **site** — the Impressum, the house rules,
  # the member directory. The router answers it, and the discriminator is the
  # matched route's **first** segment: a literal one is a fixed address of this
  # installation, a dynamic one is where a handle stands (so a reserved word
  # nobody routed, `/stefan`, keeps the answer a typo gets). Nothing here reads
  # the database, so no address can learn anything from it that fetching the
  # URL would not already tell. `Endpoint.host/0` rather than the pasted host:
  # `local_path/1` has already ruled the address ours, `www.` and all.
  defp site_page(segments) do
    case PhoenixRouter.route_info(Router, "GET", segments, Endpoint.host()) do
      %{route: route} ->
        if fixed_address?(route), do: {:error, :not_reportable}, else: {:error, :not_found}

      :error ->
        {:error, :not_found}
    end
  end

  defp fixed_address?(route) do
    case String.split(route, "/", trim: true) do
      [first | _] -> not String.starts_with?(first, [":", "*"])
      [] -> true
    end
  end

  # A member's post and a page's post. Both by id: the handle or the slug in
  # front of it is only how the URL was spelled on the day it was copied.
  defp from_segments(["organizations", _slug, "posts", id]), do: visible_post(id)

  # The authorizing media proxies. Right-clicking a photo or a video in a post
  # copies one of these, and what is reportable is the post that carries it —
  # the freeze takes the post down with its media.
  defp from_segments(["post_images", token, _version]),
    do: post_of(Posts.get_image_by_token(token))

  defp from_segments(["post_videos", token, _file]),
    do: post_of(Videos.get_video_by_token(token))

  # A press photo or a logo variant (issue #2089), by any of the four addresses
  # it has: the served versions, the stand-in, the download and a logo's PNG all
  # hang off one path shape, and what a journalist copies is whichever of them
  # their browser gave them. Unlike a post's photo the **picture** is the
  # reportable thing here — it is published on its own, for redistribution, and
  # the freeze takes exactly it offline.
  defp from_segments(["system", "press_kit", token | _rest]),
    do: visible_press_picture(token)

  # A profile picture or cover, by two of the three addresses one has. The
  # served files sit in an id-scoped public tree (`/avatars/<user id>/…`),
  # which is what a "copy image address" hands over; the third spelling,
  # `/<handle>/avatar.jpg`, is below the reserved-word clause because its first
  # segment is a handle.
  defp from_segments(["avatars", user_id | _rest]), do: visible_image(user_id, "avatar")
  defp from_segments(["covers", user_id | _rest]), do: visible_image(user_id, "cover")

  # A page, by its own address or by any deeper path under it — its press
  # section, its jobs, its followers all still name the page, which is the
  # reportable thing there. The twin of the `[handle | _rest]` clause below, and
  # what makes a pasted `/organizations/acme/press` a notice about the page
  # rather than the "correct address, nobody's content" a site page gets
  # (issue #2089). The post permalink above is the exception, and it is above
  # for that reason.
  defp from_segments(["organizations", slug | _rest]),
    do: ok_or_nil(Organizations.fetch_visible_organization(slug, nil))

  defp from_segments(["jobs", slug]), do: ok_or_nil(Jobs.fetch_visible_job_posting(slug, nil))

  # A reserved word is never a handle — keeping the URL root claimable is the
  # whole purpose of that list, and `reserved_slugs_router_test.exs` keeps it in
  # step with the router. So the clauses below, which all read their first
  # segment as somebody's handle, must not claim these paths: `/system/members/w`
  # read as "the member `system`, missing" is what put every site page deeper
  # than one segment into the typo bucket (issue #2068). Placed after the
  # content shapes above, which start with a reserved word themselves.
  defp from_segments([first | _]) when first in @reserved, do: :no_content_shape

  defp from_segments([handle, "avatar.jpg"]), do: visible_image(visible_user(handle), "avatar")
  defp from_segments([_handle, "posts", id]), do: visible_post(id)

  # A bare handle is a member's profile, or — since members and pages share one
  # handle namespace — a page that claimed that root word. The two live in two
  # columns (`slug` above, `username` here), hence two lookups.
  defp from_segments([handle]) do
    visible_user(handle) ||
      ok_or_nil(Organizations.fetch_visible_organization_by_username(handle, nil))
  end

  # A deeper path under a member's handle (a section page, a list) still names
  # that member, which is the reportable thing there.
  defp from_segments([handle | _rest]), do: visible_user(handle)

  # The site root, which is a page of ours like any other.
  defp from_segments([]), do: :no_content_shape

  defp ok_or_nil({:ok, record}), do: record
  defp ok_or_nil(_), do: nil

  defp post_of(%{post_id: post_id}) when is_binary(post_id), do: visible_post(post_id)
  defp post_of(_), do: nil

  defp visible_post(nil), do: nil

  defp visible_post(id) do
    with post when not is_nil(post) <- Moderation.fetch_content("post", id),
         true <- Posts.visible_to?(post, nil) do
      post
    else
      _ -> nil
    end
  end

  # The handle a member holds today, or the retired one they used to answer to
  # — a pasted URL is often older than the rename. One query, because the miss
  # is the common case: an organization handle and every typo fall through here.
  defp visible_user(handle) do
    with %User{} = user <- lookup_user(handle),
         true <- Moderation.profile_visible_to?(user, nil) do
      user
    else
      _ -> nil
    end
  end

  defp lookup_user(handle) do
    Repo.one(
      from(u in User,
        where: u.username == ^handle or u.legacy_username == ^handle,
        order_by: [asc: fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", u.username, ^handle)],
        limit: 1
      )
    )
  end

  # A picture resolves only while it is the one on the profile: `profile_image/2`
  # reads the member's current row for that kind, so a replaced picture is not
  # reachable through the address the old file had. A picture another case
  # already holds is not offered either — it is off the site, and reporting it
  # again would say the notice did something it did not.
  # Only a picture an anonymous visitor can already fetch, which is the whole
  # module's rule and here also the freeze's: a picture a case already took down
  # answers 404 at every one of its addresses, so resolving it would tell a
  # stranger it exists. `visible_to?/2` with no viewer is that question,
  # released picture and visible owner included.
  defp visible_press_picture(token) do
    case PressKit.get_by_token(token) do
      %Image{} = image -> if PressKit.visible_to?(image, nil), do: image
      nil -> nil
    end
  end

  defp visible_image(nil, _kind), do: nil

  defp visible_image(%User{} = owner, kind) do
    case Images.profile_image(owner.id, kind) do
      %{frozen_at: nil} = image -> image
      _ -> nil
    end
  end

  defp visible_image(user_id, kind) when is_binary(user_id) do
    UUIDv7.with_cast(user_id, fn uuid -> visible_image(visible_user_by_id(uuid), kind) end)
  end

  defp visible_user_by_id(id) do
    case Repo.get(User, id) do
      %User{} = user -> if Moderation.profile_visible_to?(user, nil), do: user
      nil -> nil
    end
  end
end
