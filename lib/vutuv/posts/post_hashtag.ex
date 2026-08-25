defmodule Vutuv.Posts.PostHashtag do
  @moduledoc """
  A tag a member's post body names as a `#hashtag`, filed so `/tags/:slug` lists
  the post (`Vutuv.Tags.Timeline`).

  Kept apart from `Vutuv.Posts.PostTag` on purpose. `post_tags` is what the card
  renders as the tag chips under a post — the tags the author *chose* in the
  composer's tag field. A hashtag is already visible in the sentence it was
  written in, so filing it there would print it twice, once as prose and once as
  a chip the author never added. `Vutuv.Posts.visible_tagged_posts_query/0`
  unions the two, so every reader asking which posts carry a tag sees both and
  neither surface changes.

  There is deliberately no changeset: the tag ids come from
  `Vutuv.Tags.tag_ids_for_hashtags/2`, which mints the topics the body is the
  first thing here to name, and the rows are re-derived from the body on every
  save.
  """

  use VutuvWeb, :model

  schema "post_hashtags" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end
end
