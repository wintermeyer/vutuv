defmodule Vutuv.Posts.Post do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.MarkdownContent
  alias Vutuv.Mentions
  alias Vutuv.Posts.GalleryLayout
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Translations

  @max_body_length 20_000

  schema "posts" do
    field(:body, :string, default: "")

    # The language the author declared in the composer (issue #1489), a
    # lowercase primary language subtag ("de", "en"). NULL (legacy posts,
    # undeclared) means: shown to everyone, never auto-translated, no AS2
    # `contentMap` outbound.
    field(:language, :string)

    # When the language detection last looked at this post (issue #1535) —
    # the sweep's own clock, set on every outcome, including the one where the
    # text could not be placed and `language` stays NULL. Nothing casts it.
    field(:language_checked_at, :utc_datetime)

    # When the background pre-translation sweep last CONSIDERED this post —
    # its own clock, stamped on every outcome including "nothing to do here",
    # which is what keeps an already-translated post from holding the front of
    # every batch forever. Owned by `Vutuv.Translations`, never cast, and
    # never written through a changeset: a post whose `updated_at` moves reads
    # as edited, and a sweep must not put that mark on posts nobody touched.
    field(:translations_enqueued_at, :utc_datetime)

    # The bento arrangement the author picked for a multi-photo post, one of
    # the `Vutuv.Posts.GalleryLayout` names; nil = automatic (the mosaic's
    # orientation-driven choice). Presentation only — the agent formats list
    # the photos regardless of how the HTML tiles them.
    field(:gallery_layout, :string)
    # Whether the bento tiles are FILLED by their photos (object-cover, which
    # crops them to the tile). Default false: the mosaic shows whole photos,
    # letterboxed inside their tiles — nobody's picture loses its edges
    # without the author asking for it.
    field(:gallery_fill?, :boolean, default: false)

    # The license the post's photos are published under (issue #1104), from
    # the fixed `Vutuv.Posts.PhotoLicense` vocabulary. It rides on the post,
    # not the photo: a set of pictures posted together is one act of
    # publishing, and a per-photo licence picker would be a forest of selects
    # for a case nobody has.
    field(:license, :string, default: "arr")
    # The archive coordinate (/:slug/posts/2026/06/06): the UTC date at
    # insert time, set programmatically, never cast from params. The
    # permalink itself is the post id (a UUID v7).
    field(:published_on, :date)
    # Set while the post is in the moderation freezer: hidden from everyone
    # but the author and admins. Managed by Vutuv.Moderation, never cast.
    field(:frozen_at, :naive_datetime)

    # True while any attached photo is still waiting for the AI image scan
    # (issue #1104). It is **not** a visibility flag: the post publishes at
    # once, and the unjudged picture alone is withheld (a placecard tile stands
    # in for it until the verdict lands). What it drives is the author's
    # progress panel, via `Vutuv.Posts.held_for_image_check?/1`. Denormalised
    # from `images` so that stays a boolean test rather than a subquery paid
    # per rendered card; `Vutuv.Posts.refresh_images_pending/1` owns it and it
    # is never cast from params.
    field(:images_pending?, :boolean, default: false)
    # Postgres-generated tsvector over body (see the migration); referenced
    # only by search_public/2's fragments, never loaded or written by Ecto.
    field(:search_tsv, :string, load_in_query: false)

    # The author, in exactly one of two shapes (issue #1334, CHECK-enforced):
    # a member (`user`), or an organization (`organization`) with the member who
    # pressed publish recorded beside it in `acting_user`. Never both, never
    # neither. Read it through `Vutuv.Posts.author/1` rather than by picking one
    # of these fields — that accessor is the single decision about which one
    # speaks, and there are ~70 places that ask.
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)

    # Who published this in the organization's name. Public rendering never
    # shows it — the author is the organization — but it survives that member
    # leaving (`nilify_all`), because the organization's content must outlive
    # them while the record of who spoke stays as long as it can.
    belongs_to(:acting_user, Vutuv.Accounts.User, foreign_key: :acting_user_id)

    # Present iff this post is a reply; survives parent deletion (see PostReply).
    has_one(:reply_ref, Vutuv.Posts.PostReply, foreign_key: :post_id)

    # Present iff this reply also answers a reply from another network (issue
    # #1070). Rides alongside `reply_ref`, never instead of it, and carries its
    # own copy of the delivery target so it outlives the cached remote note.
    has_one(:remote_reply_ref, Vutuv.Posts.PostRemoteReply, foreign_key: :post_id)

    has_many(:denials, Vutuv.Posts.PostDenial, on_replace: :delete)
    has_many(:images, Vutuv.Posts.PostImage, preload_order: [asc: :position])

    # The auto-generated link screenshot: present iff this post carried a single
    # URL and no image at save time (see Vutuv.Posts.Screenshots). Rendered
    # beside the body once `status: "ready"`.
    has_one(:screenshot, Vutuv.Posts.PostScreenshot)

    # The structured book/film review riding on this post (see PostReview);
    # nil for ordinary posts. Replaced wholesale on edit, deleted when the
    # author clears the review kind.
    has_one(:review, Vutuv.Posts.PostReview, on_replace: :delete)

    has_many(:post_tags, Vutuv.Posts.PostTag, on_replace: :delete)
    has_many(:tags, through: [:post_tags, :tag])

    # The tags the BODY names as `#hashtags` — a separate filing from the
    # composer's tag field above, re-derived on every save. Deliberately not
    # exposed as a `:tags`-style through assoc: nothing renders these (the
    # hashtag is already in the text), they exist so `/tags/:slug` can list the
    # post. See `Vutuv.Posts.PostHashtag`.
    has_many(:post_hashtags, Vutuv.Posts.PostHashtag, on_replace: :delete)

    timestamps()
  end

  def max_body_length, do: @max_body_length

  @doc """
  What an author's language declaration may store: a known `Vutuv.Languages`
  code (normalized to its primary subtag), anything else nil — undeclared,
  never a guess and never a failed post. The rule itself lives with the other
  language columns (`Vutuv.Translations.cast_language/1`), which the AS2
  ingest and the detector read too.
  """
  defdelegate cast_language(value), to: Translations

  def changeset(post, params \\ %{}) do
    post
    # empty_values: [] so clearing the body on edit is a real change ("" must
    # not be swallowed as "no change") — a photo-only post has an empty body.
    |> cast(params, [:body, :license, :gallery_layout, :gallery_fill?, :language],
      empty_values: []
    )
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, max: @max_body_length)
    # An unknown language becomes nil (undeclared) rather than a validation
    # error — the license principle: a tampered select must not fail a post.
    |> update_change(:language, &cast_language/1)
    # Whoever writes `language` owns its clock (issue #1535).
    |> Translations.reset_language_check()
    # An unknown licence becomes the safe default rather than a validation
    # error: a tampered select must not be able to fail a post, and "all
    # rights reserved" is the answer that grants nothing.
    |> update_change(:license, &PhotoLicense.cast/1)
    # Same idea for the bento arrangement: an unknown name means "automatic"
    # (nil), never a failed post.
    |> update_change(:gallery_layout, &GalleryLayout.cast/1)
    # A post body may embed only its own uploaded images (`![](…)` with a
    # `/post_images/<token>/<version>` URL, optional alignment fragment) —
    # never a remote hotlink, which would leak every reader's IP. The renderer
    # enforces ownership at display time (`VutuvWeb.Markdown.render_post/2`
    # only inlines the post's own attachments); this is the storage guard.
    |> MarkdownContent.validate_own_images_only()
    # A body may only mention handles that exist, so nobody can seed `@wanted`
    # into a post to reserve it (the anti-hijack partner of handle availability).
    |> Mentions.validate_mentions_exist()
    # ... and it may only name a handful of them: every mention notifies the
    # member it names, so a long list of handles under an advert is spam
    # delivered through the notification feed.
    |> Mentions.validate_mention_limit()
  end
end
