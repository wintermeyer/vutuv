defmodule VutuvWeb.ReviewCoverController do
  @moduledoc """
  The authorizing **review-cover proxy**: the fetched book cover of a post
  review is served through here, so the post's audience (deny model,
  `Vutuv.Posts.visible_to?/2`) also guards its cover, and a cover still in
  AI-moderation limbo shows to its author alone (`Vutuv.Moderation`). The
  URL's version segment is the content-fingerprinted filename
  (`cover-<hash>.avif`), so only the currently stored cover ever resolves;
  denied and unknown are both 404 (`VutuvWeb.ImageProxy`).
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias Vutuv.Posts.PostReview
  alias Vutuv.ReviewCover
  alias VutuvWeb.ImageProxy

  def show(conn, %{"id" => id, "version" => version_file}) do
    viewer = conn.assigns[:current_user]

    with review when not is_nil(review) <- Posts.get_review(id),
         version when not is_nil(version) <- parse_version(version_file, review),
         true <- cover_visible?(review, viewer) do
      ImageProxy.serve(conn, version,
        accel_path: &ReviewCover.accel_path(review, &1),
        version_path: &ReviewCover.version_path(review, &1)
      )
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # The whitelist is exactly the fingerprinted name the stored cover yields —
  # an ISBN change rotates the URL, an outdated one stops resolving.
  defp parse_version(version_file, review) do
    ImageProxy.parse_version(version_file, List.wrap(ReviewCover.version_name(review)))
  end

  defp cover_visible?(review, viewer) do
    Posts.visible_to?(review.post, viewer) and
      (PostReview.cover_ready?(review) or Posts.author?(review.post, viewer))
  end
end
