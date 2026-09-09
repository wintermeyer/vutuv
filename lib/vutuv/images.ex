defmodule Vutuv.Images do
  @moduledoc """
  The one table every stored picture ends up in, and the per-kind facts that do
  not belong on a row. The whole story — why the table exists, what is expand
  and what is contract, and what a member row still holds meanwhile — is in
  `docs/architecture/images.md`.

  Two kinds of picture live here, at two different stages of the same move.

  **A profile picture and cover: this release writes both and reads the row**,
  falling back to the columns when there is no row yet. Such a picture is a row
  here *and* the four columns it has always lived in on the member row; every
  write still fills both, and since #2027 the row is what every URL builder and
  every display gate reads (`member_image/2`). Its third answer, the **bridge**,
  reads those columns for a picture the backfill has not reached, so taking this
  release before running `mix vutuv.images.backfill` cannot blank every face on
  the site. Bridge and column writes go together, in the deploy before the
  migration — which is the only order a blue/green switch allows, since a
  migration may drop only what the *currently deployed* release has stopped
  reading.

  **A review's cover (#2055, the last of #2015): this release writes both and
  reads the review row.** Its truth is `cover` / `cover_status` /
  `cover_moderation` on `post_reviews` — columns on a parent row, the profile
  shape rather than the gallery one, so it joins on `images.post_review_id`
  and `sync_review_cover/1` is its one door. Nobody uploaded it, so it has no
  member owner and a check constraint says so.

  **A gallery picture (#2015: a job-posting picture first in #2054, a post
  photo in #2052, an organization image in #2053): this
  release writes both and reads the old table.** Its truth is still its own row
  — the proxy, the form and the AI gate all work off that — and the row here is
  a mirror, written by `mirror/2` and dropped by `forget/2`, joined on the
  `token` both carry rather than by a pointer. Nothing here reads it yet, which
  is why `freeze/1` raises for one and `takedown_ready?/1` answers false: a case
  opened on a row nobody consults would take nothing offline. **Such a kind
  moves in three releases**: the mirror, then the one that moves the readers and
  wires the takedown, then the migration that retires the old table.
  `docs/architecture/images.md` spells the three out.

  `serving/1` is the second thing here that is not a column: how a kind reaches
  a reader decides what its off switch is, and a kind nobody has declared
  raises rather than inheriting one.
  """

  import Ecto.Query, warn: false

  alias Vutuv.Accounts.User
  alias Vutuv.Images.Image
  alias Vutuv.PressKitStore
  alias Vutuv.Repo
  alias Vutuv.Uploads

  # The two kinds that live *only* here: a member's profile picture and cover,
  # whose truth is still the four columns on the member row beside them.
  # `Vutuv.Moderation.ImageScans` uses the same strings for its scan kinds, so
  # a scan row and an image row name the same thing.
  @profile_kinds ~w(avatar cover)

  # Every kind that has a row in this table. Written out rather than derived
  # from `@mirrored` below, because a contract release **deletes** an entry
  # there — at which point that kind lives here and nowhere else, so dropping
  # it from this list would be exactly backwards.
  # `press_kit` (#2083) is the first kind that is **born** here: every other one
  # arrived as a mirror of a table of its own or as columns on a parent row, so
  # it is also the first with no source to keep in step, no backfill class and
  # no contract release. `Vutuv.PressKit` is its context.
  @kinds ~w(avatar cover job_posting_image organization_image post_image press_kit review_cover)

  # Of those, the kinds every byte of which already goes through a controller
  # that authorizes the reader first (`VutuvWeb.JobPostingImageController` asks
  # whether the reader may see the posting, `VutuvWeb.PostImageController`
  # whether they may see the post, `VutuvWeb.OrganizationImageController`
  # whether they may see the page, `VutuvWeb.ReviewCoverController` whether
  # they may see the post the review sits on) — so the row is the off switch,
  # and #2015's expand releases change nothing about how one is served.
  # Written out rather than derived from `@mirrored`, because a kind keeps its
  # serving strategy after the contract release deletes it from there — and
  # because the review cover is in no such registry at all: it is the
  # parent-column shape below, not the gallery one.
  #
  # `press_kit` (`VutuvWeb.PressKitImageController` asks whether the reader may
  # see the picture, `Vutuv.PressKit.visible_to?/2`) is in no registry but this
  # one: it has no old table and no parent row, so `images` **is** its truth
  # from the first row.
  @proxy_kinds ~w(job_posting_image organization_image post_image press_kit review_cover)

  # Of those, the kinds whose truth is still a table of their own, and
  # everything about the copy: which columns it carries, where the source rows
  # are, and the store that knows where their files are. One registry, so a
  # kind cannot be mirrored by one half of the system and invisible to the
  # other — `Vutuv.Images.Backfill` reads its whole source from here.
  #
  # The column names are identical on both sides wherever they can be, so the
  # copy is a per-field `Map.fetch!/2` rather than a translation table: a name
  # listed here that the source schema does not have raises instead of quietly
  # writing nothing. The one exception is spelled out in a `:renamed` map, and
  # `mirror_columns/1` is what reads a field back to the column it comes from —
  # both the copy and the backfill's comparison go through `mirror_attrs/2`, so
  # a rename cannot be honoured by one and skipped by the other.
  #
  # The other direction — a column added to a source table and not to this list
  # — nothing can see, so a drift test in `images_test.exs` compares the two for
  # every kind here and fails the build on it, which also means a kind added
  # below is covered the day its entry lands.
  #
  # An entry goes when that kind's contract release retires its old table,
  # together with the double write. It does **not** take the report gate with
  # it: that reads `@takedown` below, which the release before that one, the one
  # that moves the readers and wires the takedown, is what extends.
  # #2055 (review covers) adds **no** entry — a review's cover is columns on the
  # review row with no token and no table, which is the `@column_sources` shape
  # below, not this one.
  @mirrored %{
    "job_posting_image" => %{
      fields: ~w(
        token user_id job_posting_id alt position width height content_type size_bytes moderation
      )a,
      schema: Vutuv.Jobs.JobPostingImage,
      store: Vutuv.JobPostingImageStore,
      # The version the backfill's file probe asks the store for.
      preview: "thumb"
    },
    # The picture on an organization page — a logo today, a cover and the
    # description gallery on the same table (#2053). It carries the six every
    # gallery row has and nothing else, so this entry adds no column type
    # question at all; what it does add is an **owner** that is not a member.
    #
    # `organization_images.user_id` is the *uploader*, nullable and
    # `ON DELETE SET NULL`, because a page's logo outlives the account that
    # uploaded it. `images.user_id` means the opposite — a member owner, with
    # `ON DELETE CASCADE` — so copying one into the other would delete a page's
    # logo row the day its uploader leaves. The owner here is
    # `organization_id`; the uploader rides in `uploader_user_id`, whose
    # `ON DELETE SET NULL` matches its source, and `user_id` stays empty by
    # check constraint (`images_organization_kind_has_no_member_owner`).
    "organization_image" => %{
      fields: ~w(
        token organization_id uploader_user_id alt position width height
        content_type size_bytes moderation
      )a,
      # The only column in the whole registry whose name differs on the two
      # sides, and the reason is above: on `images` this fact is not `user_id`.
      renamed: %{uploader_user_id: :user_id},
      schema: Vutuv.Organizations.OrganizationImage,
      store: Vutuv.OrganizationImageStore,
      preview: "thumb"
    },
    # The largest of the four (#2052). Almost every column of `post_images` is
    # here, because the third release drops that table and the second adds no
    # migration — a column left out now is a column lost then. `crop` is not
    # new: a profile picture's crop rectangle column holds exactly what a
    # photo's does. What stays behind is `inserted_at`, and the release that
    # moves the readers has to answer for it; the reasoning and the one reader
    # that cares are in `docs/architecture/images.md`.
    "post_image" => %{
      fields: ~w(
        token user_id post_id alt caption position width height content_type size_bytes crop
        camera lens focal_length aperture shutter iso taken_at has_gps
        show_camera_info download_original download_exact moderation
      )a,
      schema: Vutuv.Posts.PostImage,
      store: Vutuv.PostImageStore,
      # `thumb` is derived for every stored photo and is the smallest of them;
      # `lite` and `xl` are deliberately not, because both are allowed to be
      # missing on a picture the regeneration has not reached.
      preview: "thumb"
    }
  }

  @doc "The image kinds that live in this table today."
  def kinds, do: @kinds

  @doc """
  Whether this kind still lives in a table of its own that this release mirrors
  into `images` — what the generic moderation paths ask before writing the
  second copy, so a kind #2015 has not reached yet is passed over rather than
  mirrored into nothing.
  """
  def mirrored?(kind) when is_binary(kind), do: is_map_key(@mirrored, kind)

  @doc "The kinds `mirrored?/1` answers true for."
  def mirrored_kinds, do: @mirrored |> Map.keys() |> Enum.sort()

  @doc """
  Everything the mirror of a kind is made of: the `:fields` it copies, the
  `:schema` the source rows live in, the `:store` that owns their files and the
  `:preview` version a file probe asks for. `Vutuv.Images.Backfill` builds its
  whole source from this, so there is no second per-kind list to keep in step.
  """
  def mirror_source(kind) when is_map_key(@mirrored, kind), do: @mirrored[kind]

  # Each kind's copy resolved once, at compile time: `{images column, source
  # column}` per field, identical names except where the entry's `:renamed` map
  # says otherwise. Doing it here rather than per row means the attach loop and
  # the backfill's row-by-row comparison never look a rename up again.
  @mirror_pairs Map.new(@mirrored, fn {kind, config} ->
                  renamed = Map.get(config, :renamed, %{})
                  {kind, Enum.map(config.fields, &{&1, Map.get(renamed, &1, &1)})}
                end)

  @doc """
  The source column each field of `mirror_source/1`'s `:fields` is copied from,
  in the same order — the same name everywhere except where that entry's
  `:renamed` map says otherwise. What the drift test compares the source schema
  against, so a renamed column is still checked in the direction that matters:
  a column added to a source table and never mirrored.
  """
  def mirror_columns(kind) when is_map_key(@mirror_pairs, kind),
    do: Enum.map(@mirror_pairs[kind], &elem(&1, 1))

  @doc """
  The mirror row this source row becomes, as a plain map of `images` column to
  value — the one place a field is read off the source, so `mirror/2`'s copy and
  `Vutuv.Images.Backfill`'s "has it drifted" comparison cannot answer
  differently about a renamed column.
  """
  def mirror_attrs(kind, source) when is_map_key(@mirror_pairs, kind) do
    Map.new(@mirror_pairs[kind], fn {field, column} -> {field, Map.fetch!(source, column)} end)
  end

  @doc """
  How this kind reaches a reader.

    * `:static` — the derived files sit in a public tree nginx serves straight
      off disk, so nothing asks this application for permission and the only
      off switch is moving the bytes out of that tree: the quarantine tree
      while the AI gate has not ruled (`Vutuv.Uploads.quarantine_dir/1`), the
      takedown hold while a copyright case runs
      (`Vutuv.Uploads.hold_dir/1`, `freeze/1` below).
    * `:proxy` — every byte goes through a controller that authorizes the
      reader first, so the row is the off switch.

  Raises for an undeclared kind: a picture that inherits a default is one
  nobody knows how to take offline.
  """
  def serving(kind) when kind in @profile_kinds, do: :static

  def serving(kind) when kind in @proxy_kinds, do: :proxy

  def serving(kind),
    do:
      raise(ArgumentError, """
      no serving strategy declared for image kind #{inspect(kind)}. \
      Declare it in Vutuv.Images.serving/1 — a kind that inherits a default \
      is a picture nobody knows how to take offline.\
      """)

  # Which member-row column holds what for a profile picture, plus the uploader
  # that owns its files. The one place these names are written: the backfill
  # (`Vutuv.Images.Backfill`), `Vutuv.Moderation.ImageSubjects` and
  # `Vutuv.Accounts` all read them from here, so the contract deploy that drops
  # the four columns per kind has one list to delete rather than four copies to
  # find.
  @profile_columns %{
    "avatar" => %{
      file: :avatar,
      fingerprint: :avatar_fingerprint,
      crop: :avatar_crop,
      moderation: :avatar_moderation,
      pointer: :avatar_image_id,
      # The `belongs_to` the pointer backs. Beside it because `member_image/2`
      # takes the preload when a caller remembered one and falls back to the
      # pointer when nobody did.
      assoc: :avatar_image,
      module: Vutuv.Avatar,
      prefix: "avatars",
      # The version a human is shown this kind at — the report form and the two
      # case pages. Per kind here rather than branched at those call sites,
      # which is what `@profile_columns` is for.
      preview: :medium
    },
    "cover" => %{
      file: :cover_photo,
      fingerprint: :cover_fingerprint,
      crop: :cover_crop,
      moderation: :cover_moderation,
      pointer: :cover_image_id,
      assoc: :cover_image,
      module: Vutuv.Cover,
      prefix: "covers",
      preview: :wide
    }
  }

  @doc """
  The member-row columns this kind still lives in, keyed by what each holds
  (`:file`, `:fingerprint`, `:crop`, `:moderation`, `:pointer`), plus the
  `:module` that owns the files, its on-disk `:prefix` and the `:preview`
  version a human is shown it at.
  """
  def member_columns, do: @profile_columns
  def member_columns(kind) when is_map_key(@profile_columns, kind), do: @profile_columns[kind]

  # Every kind whose truth is still **columns on a parent row** rather than a
  # table of its own, in one shape whatever the parent is. Two parents today:
  # a member row (avatar, cover — the four columns above) and a review row
  # (`review_cover`, #2055).
  #
  #   * `:schema` — where the parent rows are.
  #   * `:owner`  — the `images` column naming the parent. It is what the
  #     mirror is joined on, and what the delete cascades through.
  #   * `:copied` — `images` column to parent column, the whole of the copy.
  #   * `:pointer` / `:assoc` — the parent's own pointer back at the row, for
  #     a parent that had no stable handle of its own (#2013 added
  #     `users.avatar_image_id` for exactly that). **Absent for a review**: a
  #     review row has an id and at most one cover, so `post_review_id` is
  #     already a well-defined join key and there is no second copy of the
  #     link to keep in step — and therefore no `missing_pointer` class in
  #     `Vutuv.Images.Backfill`.
  #
  # Derived from `@profile_columns` above rather than written out beside it,
  # so the two cannot say different things about an avatar.
  #
  # **A review cover has no member owner, and that is a constraint, not a
  # convention.** Nobody here uploaded it: it is a publisher's picture fetched
  # from Open Library beside a review (`Vutuv.Posts.ReviewCovers`), so a
  # refusal notifies nobody the way it does for an upload. `images.user_id`
  # means a member *owner* and is `ON DELETE CASCADE`, so naming the reviewer
  # there would arm a deletion on somebody else's picture — and the post under
  # the review need not have a member author at all, since an organization
  # publishes reviews too and `posts.user_id` is NULL for those. The review
  # owns it, `images_review_kind_owned_by_review` holds that shape in the
  # database, and this kind is deliberately **not** in
  # `images_profile_kind_has_owner`.
  @column_sources @profile_columns
                  |> Map.new(fn {kind, config} ->
                    {kind,
                     Map.merge(
                       %{
                         schema: User,
                         owner: :user_id,
                         # Taken rather than re-assigned key by key, so a
                         # transposition (`fingerprint: config.crop`) cannot
                         # compile in the one map whose whole purpose is that
                         # the two cannot disagree.
                         copied: Map.take(config, [:file, :fingerprint, :crop, :moderation])
                       },
                       Map.take(config, [:pointer, :assoc])
                     )}
                  end)
                  |> Map.put("review_cover", %{
                    schema: Vutuv.Posts.PostReview,
                    owner: :post_review_id,
                    # `post_reviews.cover` and `cover_moderation` are
                    # varchar(255), the types `file` and `moderation` already
                    # are. `cover_status` stays behind on purpose: it is the
                    # *fetch* lifecycle (none → pending → ready/failed) and
                    # there is no picture at all while it is not "ready", so
                    # the row's existence already says everything a mirrored
                    # copy could. `fingerprint` stays empty for the same
                    # reason in reverse — the content hash is *inside* `cover`
                    # (`Vutuv.ReviewCover.version_name/1` reads it back out),
                    # and a second column holding it would be one fact in two
                    # places. Both are written down in
                    # `docs/architecture/images.md` for the release that moves
                    # the readers.
                    copied: %{file: :cover, moderation: :cover_moderation},
                    # This parent keeps no pointer back at the row — a review
                    # has one cover and `post_review_id` is already a
                    # well-defined join key — so it carries its own repair
                    # instead, the way a gallery source carries its `:store`.
                    # `Vutuv.Images.Backfill` reads both from here rather than
                    # branching on the parent, so a second such kind is an
                    # entry rather than three more clauses.
                    sync: {__MODULE__, :sync_review_cover},
                    store: Vutuv.ReviewCover
                  })

  @doc """
  Where a kind whose truth is still columns on a **parent row** keeps them, in
  one shape whatever the parent is — the member row for a profile picture and
  a cover, the review row for a review cover (#2055).
  `Vutuv.Images.Backfill` reads its whole `%{cols: …}` source from here.
  """
  def column_source(kind) when is_map_key(@column_sources, kind), do: @column_sources[kind]

  @doc "The kinds `column_source/1` answers for."
  def column_kinds, do: Map.keys(@column_sources)

  @doc """
  The row this parent row becomes, as a plain map of `images` column to value —
  the `column_source/1` twin of `mirror_attrs/2`, and for the same reason: the
  write and `Vutuv.Images.Backfill`'s "has it drifted" comparison have to read
  one list. A column added to a source's `:copied` map that only one of them
  honoured would leave the backfill correcting a row forever with a statement
  that never writes the column.
  """
  def column_attrs(kind, parent) when is_map_key(@column_sources, kind) do
    Map.new(@column_sources[kind].copied, fn {field, column} ->
      {field, Map.fetch!(parent, column)}
    end)
  end

  @doc """
  The member-row column pointing at this kind's row. The one place that name is
  written; `Vutuv.Accounts`, `Vutuv.Uploads` and
  `Vutuv.Moderation.ImageSubjects` all read it from here.
  """
  def pointer_field(kind) when is_map_key(@profile_columns, kind),
    do: @profile_columns[kind].pointer

  @doc """
  This member's picture of `kind` as its row — **the** source every URL builder
  and every display gate reads since #2027, and the one place that resolution
  happens.

  Three answers, in order. The `belongs_to` when a caller preloaded it; one
  primary-key lookup on the pointer when nobody did (half the callers hand over
  a bare row straight from a query, and a picture that depends on whether
  somebody remembered a preload is not an answer); and, when there is no row at
  all, **the member row's own four columns, read as if they were one**.

  That third answer is `bridge/2`, and it is the reason this release does not
  depend on `mix vutuv.images.backfill` having been run. Without it a member
  whose picture predates the `images` table would render as a member with no
  picture — no avatar, no `og:image`, no ActivityPub icon, no vCard photo —
  silently, with nothing in the log and nothing failing, and the deploy that
  ships these readers would take every face on the site down until an operator
  happened to run a manual command. Nothing enforces that command: it is not in
  `scripts/deploy.sh`, not in boot, not in `/health`. So the columns, which this
  release still writes anyway, stand in.

  **The bridge is temporary and belongs to the same deploy as the writes.** The
  order is: this release, then the backfill with a green
  `Vutuv.Release.check_image_rows/0`, then the release that drops both the
  bridge and the column writes, then the migration. See
  `docs/architecture/images.md`.

  `nil` for a member with no picture of that kind, which costs no query at all —
  the commonest answer by a wide margin (72 % of the members on the production
  copy have none).

  Accepts any map, so the render kit's `<.avatar user={…}>` can pass whatever a
  page handed it; a map that carries none of the three is simply a member
  without a picture.
  """
  def member_image(user, kind) when is_map_key(@profile_columns, kind) do
    config = @profile_columns[kind]

    case Map.get(user, config.assoc) do
      %Image{} = image -> image
      _none -> lookup_image(Map.get(user, config.pointer)) || bridge(user, kind, config)
    end
  end

  defp lookup_image(id) when is_binary(id), do: Repo.get(Image, id)
  defp lookup_image(_id), do: nil

  # A picture the backfill has not reached, read off the member row as the row
  # it will become. Unsaved on purpose, and its `id` is therefore nil: a caller
  # that needs a real row — the report form, which names a picture by its id —
  # has to ask for one rather than trust this. Everything that only wants to
  # *show* the picture reads the same four values either way, which is what
  # makes the deploy order-independent.
  #
  # `frozen_at` is nil because a freeze writes the row first and only a row can
  # carry one; a member with no row has no case against their picture.
  defp bridge(user, kind, config) do
    case Map.get(user, config.file) do
      nil ->
        nil

      file ->
        %Image{
          kind: kind,
          user_id: Map.get(user, :id),
          file: file,
          fingerprint: Map.get(user, config.fingerprint),
          crop: Map.get(user, config.crop),
          moderation: Map.get(user, config.moderation)
        }
    end
  end

  @doc """
  Preloads the avatar row on a member or a list of members, so a page that
  renders many avatars pays one query instead of one per picture. The name to
  reach for wherever a list of members is loaded for rendering; `member_image/2`
  then costs nothing.
  """
  def preload_avatars(users), do: Repo.preload(users, :avatar_image)

  @doc """
  Both picture rows, for the two surfaces that draw a cover as well: the
  profile and the settings form. `Repo.preload/2` costs a query per
  association, so a page that shows only faces asks `preload_avatars/1`.
  """
  def preload_member_images(users), do: Repo.preload(users, [:avatar_image, :cover_image])

  @doc """
  Whether there is a picture here a reader may fetch: false for no picture, for
  one the AI gate still holds in the quarantine tree, and for one a copyright
  case moved into the takedown hold (issue #2012). The one statement of that
  rule — `Vutuv.Uploads` asks it before building any URL, and `shown_image/2`
  above answers the narrower "is there a picture at all" question beside it.
  """
  def servable?(%Image{moderation: "pending"}), do: false
  def servable?(%Image{frozen_at: %NaiveDateTime{}}), do: false
  def servable?(%Image{}), do: true
  def servable?(nil), do: false

  @doc """
  The upload's own file name as far as a reader is told about it, or `nil` for
  a member with no picture of that kind and for one a copyright case holds.
  """
  def shown_file(user, kind) when is_map_key(@profile_columns, kind) do
    with %Image{} = image <- shown_image(user, kind), do: image.file
  end

  @doc """
  Every member holding a picture of that kind, with the row preloaded — the
  population the regeneration and legacy-sweep passes walk. Two statements for
  the whole table, so a pass over 1,700 pictures does not resolve a row per
  member.
  """
  def members_with_picture(kind) when is_map_key(@profile_columns, kind) do
    config = @profile_columns[kind]

    from(u in User, where: not is_nil(field(u, ^config.pointer)))
    |> Repo.all()
    |> Repo.preload(config.assoc)
  end

  @doc """
  The member's picture of `kind` as far as a reader is even told it exists: the
  row, or `nil` both when there is none and when a copyright case froze one.

  A freeze is a takedown, so the page has to read exactly as it does for a
  member who never uploaded a picture — which is what clearing the member row's
  four columns used to do (#2012) and what the initials tile in place of the
  grey silhouette says. A picture the AI gate is merely holding is **not** this
  case: it is coming back, and it keeps the silhouette it has always shown.
  """
  def shown_image(user, kind) when is_map_key(@profile_columns, kind) do
    case member_image(user, kind) do
      %Image{frozen_at: nil} = image -> image
      _none_or_frozen -> nil
    end
  end

  @doc """
  The same, narrowed to a picture that can be **named** from outside: the report
  form addresses a picture by its row id, and `member_image/2`'s bridge answers
  with an unsaved row for a member the backfill has not reached. Such a picture
  falls back to reporting the whole profile, which is the only thing that was
  available before #2012 anyway; the backfill turns the affordance on.
  """
  def reportable_image(user, kind) when is_map_key(@profile_columns, kind) do
    case shown_image(user, kind) do
      %Image{id: id} = image when is_binary(id) -> image
      _bridged_or_none -> nil
    end
  end

  @doc """
  The crop rectangle the member positioned this picture with, or `nil` — what
  the profile form's hidden crop input starts from and what a re-derive
  re-applies.
  """
  def crop(user, kind) when is_map_key(@profile_columns, kind) do
    case member_image(user, kind) do
      %Image{crop: crop} -> crop
      nil -> nil
    end
  end

  @doc """
  Whether this member's picture of that kind is still waiting for the AI gate
  (`Vutuv.Moderation.ImageScans`) — what the profile and the settings form ask
  to show the owner their amber "visible only to you" pill.
  """
  def pending?(user, kind) when is_map_key(@profile_columns, kind) do
    match?(%Image{moderation: "pending"}, member_image(user, kind))
  end

  @doc """
  Where this member's picture of that kind actually is on disk right now, or
  `nil` when the row names a file that is not there.

  Asks the uploader rather than rebuilding a path: an unmoderated picture sits
  in the served tree under whichever of the three naming schemes its row is on
  (fingerprinted, stable-legacy, name-derived), and one still `"pending"` sits
  in the quarantine tree instead. `Vutuv.Images.Backfill.check/1` is what needs
  the distinction — "the row is right" and "the bytes are there" are two
  different questions and the cut before #2012 needs both answered.
  """
  def stored_path(user, kind, version \\ nil)

  def stored_path(%User{} = user, kind, version) when is_map_key(@profile_columns, kind) do
    config = @profile_columns[kind]
    version = version || config.preview

    case member_image(user, kind) do
      nil ->
        nil

      image ->
        # Hand the row on as the preload the uploader would otherwise look up
        # again, so one question about one picture costs one query.
        user = Map.put(user, config.assoc, image)

        if image.moderation == "pending",
          do: config.module.pending_preview_path(user, version),
          else: config.module.stored_path(user, version)
    end
  end

  @doc """
  Where this picture's bytes are **right now**, wherever that is: the takedown
  hold while a copyright case holds it (`Vutuv.Uploads.hold_dir/1`), otherwise
  the tree its member row points at. `nil` when neither has them.

  The one answer the two case pages need — a frozen picture is out of every
  tree nginx serves, so an admin ruling on a copyright claim can see it only
  through this.
  """
  def bytes_path(%Image{} = image, version \\ nil) do
    config = @profile_columns[image.kind]
    version = version || config.preview

    case Uploads.held_version_path(image.id, version, image.fingerprint) do
      path when is_binary(path) ->
        path

      nil ->
        with %User{} = owner <- owner(image),
             do: stored_path(owner, image.kind, version)
    end
  end

  @doc """
  What a reader is shown for this picture — the same URL the profile renders,
  so a picture already held by another case (or still in the AI gate) shows the
  silhouette here too rather than a URL nothing answers. For the report form.
  """
  def preview_url(%Image{} = image) do
    config = @profile_columns[image.kind]

    with %User{} = owner <- owner(image),
         do: config.module.display_url(owner, config.preview)
  end

  @doc """
  Records the picture a member just uploaded, replacing whatever row that
  member had for this kind.

  Called from `Vutuv.Accounts.store_pending_image/6` once the file is on disk,
  in the same step that fills the member row's own columns. A **fresh token**
  is minted every time, because a token names the bytes: after a re-upload, a
  report that named the old picture should point at nothing rather than quietly
  at the new one.
  """
  def put_profile_image(%User{} = user, kind, attrs) when kind in @profile_kinds do
    if frozen?(user.id, kind) do
      {:error, :frozen}
    else
      %Image{kind: kind, user_id: user.id, token: Uploads.gen_token()}
      |> Image.changeset(attrs)
      # `frozen_at` is deliberately NOT in the replace list: a freeze is a
      # takedown, and a re-upload must not be able to lift one. The guard above
      # is the readable half of the same rule — this list is what would quietly
      # undo it if somebody added the column to it.
      |> Repo.insert(
        on_conflict: {:replace, [:token, :file, :fingerprint, :crop, :moderation, :updated_at]},
        conflict_target: {:unsafe_fragment, "(user_id, kind) WHERE kind IN ('avatar', 'cover')"},
        returning: [:id]
      )
    end
  end

  @doc """
  Whether this member's picture of that kind is held by a copyright freeze.

  The question is asked at three layers on purpose, and each one is
  load-bearing: `VutuvWeb.UserController.update/2` asks before the write so the
  form can say *why* it refused rather than dropping the upload silently,
  `Vutuv.Accounts.store_pending_image/6` asks before `store/3` writes a byte —
  reading `frozen_at` off `profile_image/2` rather than calling this, since it
  needs the row anyway to know which bytes an open case named (issue #2035) —
  and `put_profile_image/3` refuses the row itself, because the row's four
  columns are what `unfreeze/1` restores from, so overwriting them would leave
  nothing to put back. Two index probes and one row read, on a path that spends
  hundreds of milliseconds encoding AVIFs.
  """
  def frozen?(user_id, kind) when kind in @profile_kinds do
    Repo.exists?(from(i in profile_query(user_id, kind), where: not is_nil(i.frozen_at)))
  end

  @doc "The member's row for this kind, or nil."
  def profile_image(user_id, kind) when kind in @profile_kinds,
    do: Repo.one(profile_query(user_id, kind))

  @doc """
  Applies the AI gate's verdict to the member's row, guarded on the bytes that
  were scanned and on the picture still waiting for one — since #2027 this row
  **is** the guard `Vutuv.Moderation.ImageSubjects` used to put on the member
  row, so it answers `:stale` for a verdict that lost a race against a
  re-upload and the caller leaves everything alone. A nil fingerprint would
  raise rather than match nothing (`where: x == ^nil` is not a silent no-op in
  Ecto), so it is answered as "no such picture".
  """
  def mark_moderation(user_id, kind, fingerprint, state)
      when kind in @profile_kinds and is_binary(fingerprint) do
    {count, _} =
      user_id
      |> profile_query(kind)
      |> where([i], i.fingerprint == ^fingerprint and i.moderation == "pending")
      |> Repo.update_all(set: [moderation: state, updated_at: now()])

    if count == 1, do: :ok, else: :stale
  end

  def mark_moderation(_user_id, _kind, _fingerprint, _state), do: :stale

  @doc """
  Drops the member's row for this kind, but only while it still names the bytes
  the scan judged — the guard `Vutuv.Moderation.ImageSubjects` needs for a
  picture the AI gate rejected, so a verdict that lost a race against a
  re-upload deletes nothing.
  """
  def discard_profile_image(user_id, kind, fingerprint),
    do: discard(user_id, kind, fingerprint, [])

  @doc """
  The same, narrowed to a picture still waiting for a verdict — which is what a
  **canceled** scan means. A picture that has since been released is not the one
  the cancel was about.
  """
  def discard_pending_image(user_id, kind, fingerprint),
    do: discard(user_id, kind, fingerprint, moderation: "pending")

  defp discard(user_id, kind, fingerprint, filters)
       when kind in @profile_kinds and is_binary(fingerprint) do
    query =
      profile_query(user_id, kind)
      |> where([i], i.fingerprint == ^fingerprint)
      |> where(^filters)

    case Repo.delete_all(query) do
      {1, _} -> :ok
      _none -> :stale
    end
  end

  defp discard(_user_id, _kind, _fingerprint, _filters), do: :stale

  @doc """
  Keeps the row's fingerprint in step when `Vutuv.Uploads.regenerate/3`
  re-derives a picture and writes a new one onto the member row. Takes the id
  of the row the re-derive read from, which is `nil` for a picture the backfill
  has not reached (`member_image/2`'s bridge) — such a picture has no row to
  keep in step, so that costs no statement.
  """
  def sync_fingerprint(image_id, fingerprint) when is_binary(image_id) do
    from(i in Image, where: i.id == ^image_id)
    |> Repo.update_all(set: [fingerprint: fingerprint, updated_at: now()])

    :ok
  end

  def sync_fingerprint(nil, _fingerprint), do: :ok

  ## The gallery kinds (issue #2015, this one #2054)

  @doc """
  Runs a write against a gallery picture's own table and mirrors the row it
  produces, in one transaction — the door every double-write call site goes
  through. `fun` returns what `Repo.insert/1` and `Repo.update/1` return, and
  the caller meets the same `{:ok, row}` / `{:error, changeset}` it always did.

  Together or not at all, for the reason the profile upload gives: by the time
  a picture's row is written its files are already on disk, so a failure
  between the two writes would leave a picture that exists everywhere except in
  the table the copyright freeze reads.
  """
  def write_mirrored(kind, fun) when is_map_key(@mirrored, kind) and is_function(fun, 0) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, row} ->
          :ok = mirror(kind, row)
          row

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Writes (or rewrites) the row that stands beside a gallery picture's own row —
  the **expand** half of moving a kind in here. Takes one source row or a list
  of them, and copies the columns `mirror_source/1` names through
  `mirror_attrs/2`, which is where the one renamed column
  (`organization_images.user_id` into `uploader_user_id`) is resolved.

  **The join key is the `token`, not a pointer.** #2013 added
  `users.avatar_image_id` because a member row had no stable handle of its own;
  a gallery row has carried one from the start, `images.token` has been unique
  across the whole table since #2013 for exactly this, and a gallery token is
  minted once and never re-minted (a re-upload is a new row). So this is an
  upsert on the token: it is idempotent, it is what makes the backfill and the
  request path the same function, and this kind has no `missing_pointer` class
  to reconcile.

  One statement however many rows are handed over, so the editor saving ten
  pictures costs one upsert rather than ten. `Repo.insert_all/3` autogenerates
  neither the id nor the timestamps, so both are minted here — `Vutuv.UUIDv7`,
  like every id in this system.

  **`kind`, `id`, `inserted_at` and `frozen_at` are deliberately not in the
  replace list.** The first three identify the row and the last is a takedown:
  a mirror that runs on every ordinary write must never be able to lift one,
  the same rule `put_profile_image/3` states for a profile picture.

  The source row's own changeset is the validation, and this must not add a
  stricter one: every column here has the type and the bound of the column it
  copies (`alt` and `content_type` are varchar(255) on both sides), so a value
  the source accepted fits, and a mirror that could refuse what the source
  stored would turn a saved picture into a failed upload.
  """
  def mirror(kind, source_or_sources) when is_map_key(@mirrored, kind) do
    fields = @mirrored[kind].fields
    now = now()

    entries =
      for source <- List.wrap(source_or_sources) do
        kind
        |> mirror_attrs(source)
        |> Map.merge(%{
          id: Vutuv.UUIDv7.generate(),
          kind: kind,
          inserted_at: now,
          updated_at: now
        })
      end

    Repo.insert_all(Image, entries,
      on_conflict: {:replace, [:updated_at | fields -- [:token]]},
      conflict_target: :token
    )

    :ok
  end

  @doc """
  Forgets the rows behind these tokens — the other half of the double write,
  called wherever the gallery's own row and its files are deleted (a discarded
  upload, a picture the editor removed on save, the pending sweep, a rejected
  scan). One statement, and a no-op for an empty list.

  A parent or a member that is deleted needs no call: `images.job_posting_id`,
  `images.post_id`, `images.organization_id` and `images.user_id` all cascade,
  and `images.uploader_user_id` nilifies — exactly as the gallery table's own
  columns do, including the one that deliberately does not cascade, so a page
  keeps its logo when the member who uploaded it closes their account.
  """
  def forget(_kind, []), do: :ok

  def forget(kind, tokens) when is_map_key(@mirrored, kind) and is_list(tokens) do
    Repo.delete_all(from(i in Image, where: i.kind == ^kind and i.token in ^tokens))
    :ok
  end

  ## The review cover (issue #2015, this one #2055)

  @review_kind "review_cover"

  @doc """
  Brings the row beside a book review's fetched cover into step with the review
  row — the **one door** for this kind, so creating the row, correcting it and
  dropping it are the same call on the request path and in
  `Vutuv.Images.Backfill`. That collapse is what #2054 got out of `mirror/2`
  for the gallery kinds; here it also removes the question of which of the
  three a caller is in, because `post_reviews.cover` is the whole state: a
  review that names a file has a row, a review that names none has none.

  Takes the review row **as it stands after the write** (any map carrying
  `:id`, `:cover` and `:cover_moderation` will do), so every caller hands over
  what it just saved rather than re-reading it.

  **The join is `post_review_id`, not a token.** A review's cover is columns on
  the review row with nothing unguessable of its own, so the token is minted
  here — and re-minted only when the bytes change, because a token names the
  bytes: after a re-fetch, a report that named the old cover should point at
  nothing rather than quietly at the new picture. One statement decides that,
  so two slots racing on the same review cannot both win.

  `frozen_at` and `inserted_at` are deliberately outside the conflict update:
  the first is a takedown an ordinary write must never lift, the second
  identifies the row.
  """
  def sync_review_cover(%{id: id, cover: nil}) when is_binary(id) do
    Repo.delete_all(from(i in Image, where: i.kind == @review_kind and i.post_review_id == ^id))

    :ok
  end

  def sync_review_cover(%{id: id, cover: cover} = review)
      when is_binary(id) and is_binary(cover) do
    now = now()

    entry =
      @review_kind
      |> column_attrs(review)
      |> Map.merge(%{
        id: Vutuv.UUIDv7.generate(),
        kind: @review_kind,
        post_review_id: id,
        token: Uploads.gen_token(),
        inserted_at: now,
        updated_at: now
      })

    Repo.insert_all(Image, [entry],
      on_conflict: review_cover_conflict(),
      conflict_target: {:unsafe_fragment, "(post_review_id) WHERE post_review_id IS NOT NULL"}
    )

    :ok
  end

  # The columns the conflict update below replaces. `fragment/1` takes a
  # literal, so this list cannot be built from the registry at run time — but a
  # column added to `:copied` and forgotten here would be written on insert and
  # skipped on update, which the backfill would meet as a row it "corrects"
  # forever with a statement that never touches the column. So the two are
  # compared at compile time instead, and disagreeing fails the build.
  @review_replaced [:file, :moderation]

  if Enum.sort(@review_replaced) != Enum.sort(Map.keys(@column_sources["review_cover"].copied)) do
    raise """
    Vutuv.Images: the review cover's @review_replaced list and the :copied map \
    in @column_sources have drifted. Every copied column has to appear in \
    review_cover_conflict/0's `set`, or an existing row never receives it.\
    """
  end

  # A `{:replace, …}` list cannot say "only when the bytes changed", and the
  # alternative — read the row, compare, then write — is two statements with a
  # race between them on a path two fetches can reach at once.
  defp review_cover_conflict do
    from(i in Image,
      update: [
        set: [
          file: fragment("EXCLUDED.file"),
          moderation: fragment("EXCLUDED.moderation"),
          token:
            fragment(
              "CASE WHEN ? IS DISTINCT FROM EXCLUDED.file THEN EXCLUDED.token ELSE ? END",
              i.file,
              i.token
            ),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  # Which takedown a kind gets, and (by the presence of a key) whether it has
  # one at all. `takedown_ready?/1` and the three functions below all guard on
  # `is_map_key(@takedown, kind)`, so the gate that lets a report name a picture
  # and the code that takes it offline read one map and cannot answer
  # differently. A kind arrives here in the same change as its strategy's
  # clauses (issue #2057).
  #
  # It is also the "how every byte of this kind is deleted" registry, not only
  # the copyright gate: `purge/1` is what an upheld case runs *and* what an
  # owner's own "remove it" runs (`Vutuv.PressKit.delete/1`), so a kind without
  # an entry has no delete path either.
  #
  # The gate used to be derived from `@mirrored` instead, and the two agreed by
  # arithmetic rather than by meaning: that entry is what a **contract** release
  # deletes, so the gate would have opened on the deploy that retires a kind's
  # old table whether or not anything had wired that kind's freeze, and the
  # first report accepted on it would have raised in front of the admin who
  # upheld it.
  #
  # `press_kit` (issue #2084) arrives with a strategy of its own rather than
  # pointing at `:profile`: there is no member row to clear (a page's press
  # picture has no member owner at all) and its files are keyed by the row's
  # token rather than by a member scope. A picture published *for
  # redistribution* is the likeliest of all of them to draw a copyright notice,
  # which is why the kind gets its takedown in the same release as its scan
  # rather than one later.
  @takedown @profile_kinds |> Map.new(&{&1, :profile}) |> Map.put("press_kit", :press_kit)

  @doc """
  Whether a copyright case can act on this picture at all — what
  `Vutuv.Moderation` asks before letting a report name it.

  True for exactly the kinds `freeze/1` below can act on (`@takedown`), because
  that is the fact the gate needs: a report accepted on a kind nothing can take
  offline opens a case whose uphold raises. A gallery kind that has only just
  arrived here (#2054 and its siblings ship the **expand** half: the row exists,
  every URL and every gate still reads the old table) is therefore refused until
  the release that wires its takedown, which leaves it the affordance it had
  before the row existed: reporting the posting or the page the picture sits on.
  """
  def takedown_ready?(%Image{kind: kind}), do: is_map_key(@takedown, kind)

  # A kind whose row exists but whose takedown does not. Loud rather than
  # half-done: the alternative is a stamped `frozen_at` no reader consults and
  # files nothing moved, which reads from the case page exactly like a
  # completed takedown.
  defp no_takedown_path!(%Image{kind: kind}, action) do
    raise ArgumentError, """
    cannot #{action} an image of kind #{inspect(kind)}: nothing here can take a \
    picture of that kind offline, so nothing would go offline. Give the kind a \
    strategy in Vutuv.Images' @takedown before letting a case reach it.\
    """
  end

  ## The copyright freeze (issue #2012)

  @doc """
  Takes this picture offline without deleting a byte of it: the row is stamped
  `frozen_at`, the member row's four columns for that kind are cleared, and
  every file moves into the hold (`Vutuv.Uploads.hold/3`).

  **`frozen_at` is what a reader notices.** Since #2027 every URL builder and
  every display gate resolves the picture through this module, and `servable?/1`
  and `shown_image/2` both answer "there is nothing here" for a stamped row: the
  profile draws the initials tile, the vCard and the link-preview JPEG return
  nothing, the actor document drops its icon.

  The member row's four columns are cleared beside it because the **previous
  release is still serving from them** while the blue/green switch runs, and it
  has to hide the picture too. They go with the migration that drops them.
  Nothing is lost either way, because the row holds the same four values:
  `unfreeze/1` writes them back.

  **Order matters.** The stamp goes first: it is the record that this picture is
  meant to be held, so a slot that dies mid-move leaves a picture that is
  already invisible and a job `reconcile_holds/0` finishes. The other order
  would leave files in a hold that nothing knows to bring back.
  """
  def freeze(%Image{kind: kind} = image) when is_map_key(@takedown, kind) do
    # The stamp is the same statement whatever the strategy is, so it is here
    # rather than copied into each of them. `is_nil(frozen_at)` so a second pass
    # — `reconcile_holds/0` finishing an interrupted move — re-asserts the
    # freeze without moving the moment it happened, which is what the case and
    # the statement of reasons quote.
    {_count, _} =
      Repo.update_all(from(i in Image, where: i.id == ^image.id and is_nil(i.frozen_at)),
        set: [frozen_at: now(), updated_at: now()]
      )

    freeze_by(@takedown[kind], image)
  end

  def freeze(%Image{} = image), do: no_takedown_path!(image, "freeze")

  # The profile strategy: the files are served straight off disk (`serving/1`
  # answers `:static`), so taking the picture offline means moving them.
  defp freeze_by(:profile, %Image{} = image) do
    hide_from_member_row(image)

    with %User{} = user <- owner(image),
         do: @profile_columns[image.kind].module.hold(image.id, user)

    :ok
  end

  # The press-kit strategy. Every byte already goes through an authorizing
  # proxy, so `frozen_at` alone takes the picture off every page and out of
  # every download (`Vutuv.PressKit.visible_to?/2` refuses a stamped row to
  # everybody, its owner and an admin included) — the file move is what makes
  # the hold a *hold* rather than a flag, so an upheld case has the bytes to
  # delete and a rejected one has them to put back.
  defp freeze_by(:press_kit, %Image{} = image) do
    PressKitStore.hold(image)
    :ok
  end

  @doc """
  Puts a frozen picture back exactly where it was: every file returns to the
  tree it came from under the name it had, the member row gets its four columns
  back from the row, and the hold is removed.

  The URL therefore comes back unchanged, which is the point — other servers,
  search engines and sent mail all hold it. The one case where the bytes cannot
  simply move back is a member who renamed while their picture was held (the
  handle is baked into the served file name), so the same self-heal
  `Vutuv.Uploads.promote_from_quarantine/2` uses runs afterwards and re-derives
  from the original under the current handle.

  Idempotent, and safe to run again after an interruption: the hold is removed
  only once the member row names the files again, so a half-finished restore is
  still a hold for `reconcile_holds/0` to find.
  """
  def unfreeze(%Image{kind: kind} = image) when is_map_key(@takedown, kind) do
    # Cleared before the strategy runs, and the hold removed after it: an
    # interruption in between then leaves a row that is no longer frozen beside
    # a hold nothing has emptied, which `reconcile_holds/0` reads as an
    # unfinished release and finishes. The other order would leave a frozen row
    # with its files already back, which that same pass would dutifully freeze
    # again.
    {_count, _} =
      Repo.update_all(from(i in Image, where: i.id == ^image.id),
        set: [frozen_at: nil, updated_at: now()]
      )

    unfreeze_by(@takedown[kind], image)
    Uploads.purge_hold(image.id)
    :ok
  end

  def unfreeze(%Image{} = image), do: no_takedown_path!(image, "unfreeze")

  defp unfreeze_by(:profile, %Image{} = image) do
    with %User{} = user <- owner(image) do
      config = @profile_columns[image.kind]
      config.module.release(image.id, user)

      show_on_member_row(image)
      config.module.regenerate(Repo.get!(User, user.id))
    end

    :ok
  end

  defp unfreeze_by(:press_kit, %Image{} = image) do
    PressKitStore.release(image)
    :ok
  end

  @doc """
  Deletes this picture for good — every derived version, the private original
  and the held copies — and forgets the row. What an upheld copyright case does,
  and what the owner's own "remove it" does.

  The member row is cleared first, so an interruption can only ever leave files
  nothing points at (which `reconcile_holds/0` collects), never a member row
  naming files that are gone.
  """
  def purge(%Image{kind: kind} = image) when is_map_key(@takedown, kind) do
    purge_by(@takedown[kind], image)
    Uploads.purge_hold(image.id)
    :ok
  end

  def purge(%Image{} = image), do: no_takedown_path!(image, "purge")

  defp purge_by(:profile, %Image{} = image) do
    case owner(image) do
      %User{} = user ->
        config = @profile_columns[image.kind]
        hide_from_member_row(image)
        # By id rather than by (user_id, kind), so the kinds #2015 brings —
        # which have no member owner — take the same path.
        Repo.delete_all(from(i in Image, where: i.id == ^image.id))
        config.module.delete(user)

      nil ->
        Repo.delete_all(from(i in Image, where: i.id == ^image.id))
    end

    :ok
  end

  # The row first and the files after, which is the order an interruption can
  # survive: it leaves files nothing points at (collected by
  # `reconcile_holds/0`) rather than a row naming files that are gone.
  defp purge_by(:press_kit, %Image{} = image) do
    Repo.delete_all(from(i in Image, where: i.id == ^image.id))
    PressKitStore.delete(image.token)
    :ok
  end

  @doc """
  Finishes every move a dying slot left half-done, in both directions — the
  standing job behind `freeze/1` and `unfreeze/1`, run by
  `Vutuv.Moderation.Sweeper` every 15 minutes.

  The row's `frozen_at` is the intent and the disk is the state, so this reads
  the intent and re-asserts it: a frozen picture has its member columns cleared
  again and whatever is left of it moved into the hold, a hold whose row is no
  longer frozen is released, and a hold whose row is gone (an upheld case
  interrupted between the two) is deleted. Every step is the same idempotent
  function the request path runs, so a second pass over finished work writes
  nothing.
  """
  def reconcile_holds do
    # Preloaded, so re-asserting a freeze costs no lookup per picture.
    frozen = Repo.all(from(i in Image, where: not is_nil(i.frozen_at), preload: :user))
    for image <- frozen, do: freeze(image)

    frozen_ids = MapSet.new(frozen, & &1.id)
    leftover = Enum.reject(Uploads.held_image_ids(), &MapSet.member?(frozen_ids, &1))

    release_leftover_holds(leftover)

    :ok
  end

  # A hold whose row is no longer frozen goes back; a hold whose row is gone
  # (an upheld case interrupted between the two) is deleted. One query for the
  # lot, however many there are.
  defp release_leftover_holds([]), do: :ok

  defp release_leftover_holds(image_ids) do
    rows = Repo.all(from(i in Image, where: i.id in ^image_ids, preload: :user))
    for image <- rows, do: unfreeze(image)

    known = MapSet.new(rows, & &1.id)
    for id <- image_ids, not MapSet.member?(known, id), do: Uploads.purge_hold(id)

    :ok
  end

  # The same four columns
  # `Vutuv.Moderation.ImageSubjects.clear_profile_columns/1` clears for a
  # rejected picture, minus the pointer: this row is still the member's picture
  # of that kind, it is only being held, and the pointer is how the case and
  # `unfreeze/1` find it again.
  #
  # Guarded on the file column, so a converged freeze — `reconcile_holds/0`
  # passing over work that is already done — matches no row and writes nothing.
  # This release's readers are gated on `frozen_at` and the release one back on
  # this column, so a half-cleared row is invisible to both.
  defp hide_from_member_row(%Image{user_id: user_id, kind: kind}) do
    config = @profile_columns[kind]

    Repo.update_all(
      from(u in User, where: u.id == ^user_id and not is_nil(field(u, ^config.file))),
      set: [
        {config.file, nil},
        {config.fingerprint, nil},
        {config.crop, nil},
        {config.moderation, nil}
      ]
    )

    :ok
  end

  # The pointer is deliberately left alone by both halves: it is true while the
  # picture is held (that row IS the member's picture), and a deleted row
  # nilifies it by itself.
  defp show_on_member_row(%Image{kind: kind} = image) do
    config = @profile_columns[kind]

    Repo.update_all(from(u in User, where: u.id == ^image.user_id),
      set: [
        {config.file, image.file},
        {config.fingerprint, image.fingerprint},
        {config.crop, image.crop},
        {config.moderation, image.moderation},
        {config.pointer, image.id}
      ]
    )

    :ok
  end

  # Takes the preload when it is there and looks the member up when it is not:
  # half the callers hand over a bare row straight from a query, and an answer
  # that depends on whether somebody remembered a preload is not an answer.
  defp owner(%Image{user: %User{} = user}), do: user
  defp owner(%Image{user_id: user_id}) when is_binary(user_id), do: Repo.get(User, user_id)
  defp owner(%Image{}), do: nil

  defp profile_query(user_id, kind),
    do: from(i in Image, where: i.user_id == ^user_id and i.kind == ^kind)

  defp now, do: NaiveDateTime.utc_now(:second)
end
