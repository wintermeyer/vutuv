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
  comes back `{:error, :not_found}`, which is the same answer a typo gets.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Images
  alias Vutuv.Jobs
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Videos

  @doc """
  Resolves `url` to the content row it names.

  `{:ok, content}` for a reportable, publicly visible row; `{:error,
  :foreign_host}` when the address belongs to another server (worth its own
  message: the notifier has to be told we can only act on what is here);
  `{:error, :not_found}` for anything else.
  """
  def resolve(url) when is_binary(url) do
    case Fediverse.local_path(String.trim(url)) do
      nil -> {:error, :foreign_host}
      segments -> found(from_segments(segments))
    end
  end

  def resolve(_url), do: {:error, :not_found}

  defp found(nil), do: {:error, :not_found}
  defp found(content), do: {:ok, content}

  # A member's post and a page's post. Both by id: the handle or the slug in
  # front of it is only how the URL was spelled on the day it was copied.
  defp from_segments(["organizations", _slug, "posts", id]), do: visible_post(id)
  defp from_segments([_handle, "posts", id]), do: visible_post(id)

  # The authorizing media proxies. Right-clicking a photo or a video in a post
  # copies one of these, and what is reportable is the post that carries it —
  # the freeze takes the post down with its media.
  defp from_segments(["post_images", token, _version]) do
    case Posts.get_image_by_token(token) do
      %{post_id: post_id} when is_binary(post_id) -> visible_post(post_id)
      _ -> nil
    end
  end

  defp from_segments(["post_videos", token, _file]) do
    case Videos.get_video_by_token(token) do
      %{post_id: post_id} when is_binary(post_id) -> visible_post(post_id)
      _ -> nil
    end
  end

  # A profile picture or cover, by the three addresses one has. The served
  # files sit in an id-scoped public tree (`/avatars/<user id>/…`), which is
  # what a "copy image address" hands over; `/<handle>/avatar.jpg` is the
  # scraper-friendly JPEG a link preview shows.
  defp from_segments(["avatars", user_id | _rest]), do: visible_image(user_id, "avatar")
  defp from_segments(["covers", user_id | _rest]), do: visible_image(user_id, "cover")

  defp from_segments([handle, "avatar.jpg"]) do
    case visible_user(handle) do
      %User{} = user -> visible_image(user.id, "avatar")
      _ -> nil
    end
  end

  defp from_segments(["organizations", slug]), do: visible_organization_by_slug(slug)
  defp from_segments(["jobs", slug]), do: visible_job_posting(slug)

  # A bare handle is a member's profile, or — since members and pages share one
  # handle namespace — a page that claimed that root word.
  defp from_segments([handle]), do: visible_user(handle) || visible_organization(handle)

  # A deeper path under a member's handle (a section page, a list) still names
  # that member, which is the reportable thing there.
  defp from_segments([handle | _rest]), do: visible_user(handle)

  defp from_segments(_segments), do: nil

  defp visible_post(id) do
    with post when not is_nil(post) <- Moderation.fetch_content("post", id),
         true <- Posts.visible_to?(post, nil) do
      post
    else
      _ -> nil
    end
  end

  # The handle a member holds today, or the retired one they used to answer to
  # — a pasted URL is often older than the rename.
  defp visible_user(handle) do
    with %User{} = user <- lookup_user(handle),
         true <- Moderation.profile_visible_to?(user, nil) do
      user
    else
      _ -> nil
    end
  end

  defp lookup_user(handle) do
    Repo.get_by(User, username: handle) || Repo.get_by(User, legacy_username: handle)
  end

  # `/organizations/:slug` names a page by its slug; a bare root word names it
  # by the handle it claimed. Two columns, two lookups.
  defp visible_organization_by_slug(slug) do
    case Organizations.fetch_visible_organization(slug, nil) do
      {:ok, organization} -> organization
      {:error, :not_found} -> nil
    end
  end

  defp visible_organization(handle) do
    case Organizations.fetch_visible_organization_by_username(handle, nil) do
      {:ok, organization} -> organization
      {:error, :not_found} -> nil
    end
  end

  defp visible_job_posting(slug) do
    with posting when not is_nil(posting) <- Jobs.get_job_posting_by_slug(slug),
         true <- Jobs.visible_to?(posting, nil) do
      posting
    else
      _ -> nil
    end
  end

  # A picture resolves only while it is the one on the profile: `profile_image/2`
  # reads the member's current row for that kind, so a replaced picture is not
  # reachable through the address the old file had. A picture another case
  # already holds is not offered either — it is off the site, and reporting it
  # again would say the notice did something it did not.
  defp visible_image(user_id, kind) do
    with true <- Vutuv.UUIDv7.cast_or_nil(user_id) != nil,
         %User{} = owner <- Repo.get(User, user_id),
         true <- Moderation.profile_visible_to?(owner, nil),
         image when not is_nil(image) <- Images.profile_image(owner.id, kind),
         true <- is_nil(image.frozen_at) do
      image
    else
      _ -> nil
    end
  end
end
