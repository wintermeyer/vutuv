defmodule Vutuv.Fediverse.RemotePostTag do
  @moduledoc """
  One of **our** tags that a cached remote post carries, so the tag page can
  list what other networks said about a topic (`Vutuv.Tags.Timeline`).

  The row is written from the post's hashtags — the ActivityPub `tag` array's
  `Hashtag` objects and, for servers that send none, the `#hashtags` left in the
  text — and it names a tag that **already exists here**. Ingestion mints no tag
  from a stranger's hashtag: our tag namespace is what members chose to call
  things, and a table a remote server can extend is a table a remote server can
  flood with pages on our own domain.

  There is deliberately no changeset. Nothing here is user-supplied: both ids
  come from records `Vutuv.Fediverse.Hashtags` already resolved, and the write
  is an idempotent `insert_all` against the unique index, so an upstream
  `Update` re-syncs a post's tags without a diff.

  It cascades away with the cached post, which is right rather than lossy: our
  copy of the post is a bounded cache, and a filing under a tag outliving the
  thing it files would be a tag page pointing at nothing.
  """

  use VutuvWeb, :model

  schema "fediverse_post_tags" do
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end
end
