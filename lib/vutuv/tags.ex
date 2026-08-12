defmodule Vutuv.Tags do
  @moduledoc """
  The Tags context: adding tags to users (one name or a batch of them, the path
  registration and the tags page share) and user tag endorsements.

  Tags may contain spaces ("Ruby on Rails"). When a member types a batch, only
  a **comma** separates tags — a space does not — so `"Elixir, Ruby on Rails"`
  is two tags and needs no quoting. `parse_tag_names/1` is the single tokenizer
  for that rule.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.SearchText
  require Vutuv.Tags.MatchKey

  alias Vutuv.Tags.MatchKey
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagFollow
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement
  alias Vutuv.WebAddress

  # The endorsers list: which columns it can be sorted by, and a denser page
  # size than the site-wide default so a popular tag's list actually paginates.
  @endorser_sorts ~w(name username date)
  @endorsers_per_page 25

  # How many `#hashtags` of one body are looked up and filed (a member's post
  # body, a cached remote post). Generous for anybody writing normally and a
  # ceiling on the pathological case: a body listing two hundred hashtags is
  # reaching for two hundred tag pages, not writing about two hundred topics.
  @max_hashtags_per_body 20

  # The most tags one profile may carry. A handful of members overdid it, so a
  # profile is capped here. The cap bites only when tags *change*: a profile
  # already over it (from before the cap) keeps every tag but can add none, and
  # the sign-up form validates the same ceiling up front.
  @max_user_tags 15

  # Where a tag name stops being a topic and starts being a sentence, used by
  # the one-time `delete_legacy_overlong_tags/0` cleanup. This is a cleanup
  # threshold, not a validation: nothing stops a member typing a longer name
  # today, and the question of whether the composer should cap it is separate.
  @overlong_tag_length 35

  # What separates two tags: a comma, or a line break so a pasted list of tags
  # arrives as a list rather than as one giant name.
  @separators ~r/[,\r\n]+/
  # A `#` that starts a word begins a new tag, so a pasted run of hashtags
  # ("#Elixir #Phoenix") still splits. Rewritten to a comma before the split;
  # `#` *inside* a word is untouched, so `C#` and `F#` stay whole.
  @hashtag_start ~r/\s+#/u
  # Straight, curly, German and guillemet quotes. Quoting used to be how a
  # multi-word tag was grouped; multi-word is the default now, so a quote
  # carries no meaning and is simply dropped from the name — members who
  # learned the old habit keep getting what they meant.
  @quotes ~r/["\x{201C}\x{201D}\x{201E}\x{201F}\x{00AB}\x{00BB}]/u

  @doc """
  Tokenizes a tag string into clean names. **Only a comma separates tags** — a
  space does not — so `"PHP, Ruby on Rails, Go"` is three tags and a
  multi-word tag needs no quoting: `"Ruby on Rails"` is one tag. A line break
  separates too (a pasted list), and a `#` that starts a word begins a new tag
  so a run of hashtags still splits; a `#` inside a word is part of the name
  (`C#`). Quotes are stripped wherever they appear.

  Each token then goes through `Tag.normalize_value/1`: a leading `#` (the
  hashtag form) is stripped and interior whitespace collapsed, so
  `"#Elixir, #Phoenix"` → `["Elixir", "Phoenix"]` and a bare `"#"` drops out.
  Safe to call with `nil` (returns `[]`).
  """
  def parse_tag_names(value) when is_binary(value) do
    value
    |> String.replace(@quotes, "")
    |> String.replace(@hashtag_start, ",#")
    |> String.split(@separators)
    |> Enum.map(&Tag.normalize_value/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_tag_names(_), do: []

  @doc """
  The tags a batch of typed `names` really names, in typed order: every name
  replaced by the display name of the tag it resolves to, and every duplicate
  that resolution creates dropped.

  Resolution is exactly what `Tag.create_or_link_tag/2` does one name at a
  time, batched into a single query for the whole list: an existing tag matched
  case-insensitively by name **or** slug contributes its stored display name
  (typing `"AhmetSun"` when the tag `ahmetsun` exists yields `ahmetsun`), an
  **alternative name** contributes the topic it points at (issue #1338, so
  `"ROR"` yields `Ruby on Rails`), and a name nothing matches passes through
  exactly as typed — it is about to become a fresh tag.

  The dedupe is what an alias makes necessary. `"ROR, Ruby on Rails"` is one
  topic under two names, and the member cannot see that: the two spellings look
  nothing alike, so without this the second one comes back as a failed
  duplicate on a form that had just promised both. Duplicates are dropped by
  the tag they resolve to, keeping the first spelling typed, which also
  subsumes the plain case-insensitive dedupe (`"php, PHP"`).

  **Every entry point that takes a batch owes this call**: the add-tag form,
  its live preview and sign-up all route through here, so the preview, the
  minimum-tags rule and what actually lands on the profile agree. It does not
  judge a name — a value `add_user_tag/2` refuses (a web address, punctuation)
  passes through untouched, so each caller keeps its own refusal, and its
  error, for it.
  """
  def canonical_tag_names([]), do: []

  def canonical_tag_names(names) when is_list(names) do
    resolved = resolution_by_key(names)

    names
    |> Enum.map(fn name ->
      # The same folded key the single lookup uses (`Vutuv.Tags.MatchKey`), or a
      # batch goes on counting spellings where one lookup counts topics — which
      # is what sign-up's three-tag minimum and the composer's cap of five are
      # counting. A name with nothing to key on stands for itself.
      key = MatchKey.normalize(name) || String.downcase(name)
      Map.get(resolved, key, {{:new, key}, name})
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # `{typed key => {identity, display name}}` for every name that matches a
  # stored tag, both by lowercased name and by slug (the two things
  # `Tag.find_by_value/1` matches on). The identity is the **canonical** tag's
  # id, which is what makes two different spellings of one topic collapse.
  defp resolution_by_key(names) do
    keys = names |> Enum.map(&MatchKey.normalize/1) |> Enum.reject(&is_nil/1)

    from(t in Tag,
      left_join: c in assoc(t, :merged_into),
      where: MatchKey.sql(t.name) in ^keys or MatchKey.sql(t.slug) in ^keys,
      select:
        {MatchKey.sql(t.name), MatchKey.sql(t.slug), coalesce(c.id, t.id),
         coalesce(c.name, t.name)}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {name_key, slug_key, id, name} ->
      entry = {{:tag, id}, name}
      for key <- Enum.uniq([name_key, slug_key]), is_binary(key), do: {key, entry}
    end)
    |> Map.new()
  end

  @doc """
  The display names a submit of `value` on the add-tag form will actually
  attach, in typed order — the live preview of issue #848.

  `canonical_tag_names/1` does the resolving and the deduping (and the save
  path calls it too, so preview and outcome always agree); this only drops
  first what `add_user_tag/2` would refuse — a name that is nothing but a web
  or email address, or one that is only punctuation — since promising such a
  name here would be a lie the submit then takes back. The drop happens on the
  **typed** name, before resolution, because `Tag.create_or_link_tag/2` refuses
  it before its lookup too.
  """
  def preview_tag_names(value) do
    value
    |> parse_tag_names()
    |> Enum.reject(&(WebAddress.link_only?(&1) or Tag.punctuation_only?(&1)))
    |> canonical_tag_names()
  end

  @doc """
  Tags whose name or slug contains `query`, for the admin screens.

  One definition for the tag catalog and the merge screen, so an admin who found
  a tag in one finds it in the other. `:merged` says what to do with alternative
  names: `:include` (the catalog, which marks them and links their topic) or
  `:exclude` (the merge screen, where only a real topic can be picked). A blank
  query answers with every tag, which is what the catalog's unfiltered listing
  is; pass a `:limit` where that would be too much.
  """
  def admin_search(query, opts \\ []) do
    base = if opts[:merged] == :include, do: Tag, else: Tag.not_merged()

    base
    |> admin_search_filter(String.trim(to_string(query)))
    |> admin_search_limit(opts[:limit])
  end

  defp admin_search_filter(base, ""), do: from(t in base)

  defp admin_search_filter(base, query) do
    infix = SearchText.contains(query)
    from(t in base, where: ilike(t.name, ^infix) or ilike(t.slug, ^infix))
  end

  defp admin_search_limit(query, nil), do: query

  defp admin_search_limit(query, limit) do
    from(t in query, order_by: [asc: t.name], limit: ^limit)
  end

  @doc """
  How many profiles carry each of `tag_ids`, as a map — one query for the whole
  list, so a screen showing several tags side by side costs one lookup rather
  than one per row. Tags nobody carries are absent from the map.
  """
  def member_counts([]), do: %{}

  def member_counts(tag_ids) when is_list(tag_ids) do
    from(ut in UserTag,
      where: ut.tag_id in ^tag_ids,
      group_by: ut.tag_id,
      select: {ut.tag_id, count(ut.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The most tags one profile may carry (see `@max_user_tags`)."
  def max_user_tags, do: @max_user_tags

  @doc """
  Whether `user` already holds the maximum number of tags, so `add_user_tag/2`
  would refuse the next one. Counts the live rows, so it reflects removals.
  """
  def at_user_tag_limit?(%User{} = user), do: user_tag_count(user.id) >= @max_user_tags

  @doc """
  Tags `user` with `name`, creating the global tag or linking the existing
  one. Returns the `Repo.insert` result; a duplicate or invalid name comes
  back as `{:error, changeset}`.

  Two guards, both returning `{:error, changeset}`:

    * The profile is **at the tag ceiling** (`max_user_tags/0`) — refused, so a
      member who overdid it keeps their tags but adds no more until they drop
      back under the cap.
    * The tag is an **honor** tag — reserved, granted only through
      `admin_assign_tag/2`.

  This is the single self-assign chokepoint — the tags page, the JSON API, the
  LinkedIn import and account setup all reach it — so both guards cover every
  member entry point.
  """
  def add_user_tag(%User{} = user, name) when is_binary(name) do
    if at_user_tag_limit?(user) do
      {:error, tag_limit_changeset(user)}
    else
      changeset =
        user
        |> Ecto.build_assoc(:user_tags, %{})
        |> UserTag.changeset()
        |> Tag.create_or_link_tag(%{"value" => name})

      if reserved_tag?(changeset) do
        {:error, reserved_tag_error(changeset)}
      else
        Repo.insert(changeset)
      end
    end
  end

  @doc """
  The `{:error, changeset}` a save is refused with once `user` is at the tag
  ceiling: an empty `UserTag` changeset carrying a clear, member-facing error
  and the `:insert` action, so the tags editor shows it inline and the JSON API
  returns a 422. Shared by `add_user_tag/2` and `VutuvWeb.TagNewLive` (which
  guards up front, so a full batch shows one clear message, not N failures).
  """
  def tag_limit_changeset(%User{} = user) do
    user
    |> Ecto.build_assoc(:user_tags, %{})
    |> UserTag.changeset(%{})
    |> Ecto.Changeset.add_error(
      :tag_id,
      "You can have at most %{max} tags. Remove one before adding another.",
      max: @max_user_tags
    )
    |> Map.put(:action, :insert)
  end

  defp user_tag_count(user_id),
    do: Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^user_id), :count)

  # `Tag.create_or_link_tag/2` always resolves to a `:tag_id` (it either links an
  # existing tag or mints a fresh one and links that). A member can only reach an
  # honor tag by linking the pre-existing reserved one — a freshly minted tag is
  # always `honor?: false` — so this guard only ever refuses the link case.
  # Nothing to look up unless a `:tag_id` was set.
  defp reserved_tag?(changeset) do
    case Ecto.Changeset.get_change(changeset, :tag_id) do
      nil -> false
      tag_id -> Repo.get(Tag, tag_id).honor?
    end
  end

  defp reserved_tag_error(changeset) do
    changeset
    |> Ecto.Changeset.add_error(
      :tag_id,
      "is reserved and can only be assigned by a site admin"
    )
    |> Map.put(:action, :insert)
  end

  @doc """
  Assigns an honor (or any) tag to `user`, bypassing the reservation in
  `add_user_tag/2`. The admin roster chokepoint (`VutuvWeb.Admin.TagMemberController`),
  gated by admin auth at the route. A re-assign comes back as `{:error, changeset}`
  via the composite unique constraint.
  """
  def admin_assign_tag(%Tag{} = tag, %User{} = user) do
    %UserTag{user_id: user.id, tag_id: tag.id}
    |> UserTag.changeset()
    |> Repo.insert()
  end

  @doc """
  Removes `tag` from `user` (the admin roster's remove control). Returns the
  number of rows deleted (0 or 1), so removing one that is already gone is a
  no-op rather than a raise.
  """
  def admin_unassign_tag(%Tag{} = tag, %User{} = user) do
    {count, _} =
      from(ut in UserTag, where: ut.tag_id == ^tag.id and ut.user_id == ^user.id)
      |> Repo.delete_all()

    count
  end

  @doc """
  Removes a member's own tag. The chokepoint for member self-removal (the tags
  editor and the JSON API both go through here): an **honor** tag is
  refused with `{:error, :honor}` — only an admin can take it back —
  while a normal tag is deleted and returned as `{:ok, user_tag}`.
  """
  def delete_user_tag(%UserTag{} = user_tag) do
    if UserTag.tag(user_tag).honor? do
      {:error, :honor}
    else
      {:ok, Repo.delete!(user_tag)}
    end
  end

  @doc """
  The members carrying `tag`, ordered by name — the admin roster on the tag's
  page. Narrow listing-row select, like the tag page's `recommended_users/1`.
  """
  def tag_holders(%Tag{} = tag) do
    from(u in User,
      join: ut in assoc(u, :user_tags),
      where: ut.tag_id == ^tag.id,
      order_by: [asc: u.last_name, asc: u.first_name],
      select: struct(u, ^User.listing_fields())
    )
    |> Repo.all()
  end

  @doc """
  Every honor tag with its current holder count, name-ordered — the admin
  "Honor tags" overview (`/admin/honor_tags`). Returns `[{%Tag{}, count}]`.
  """
  def honor_tags do
    from(t in Tag.not_merged(),
      where: t.honor?,
      left_join: ut in assoc(t, :user_tags),
      group_by: t.id,
      order_by: [asc: t.name],
      select: {t, count(ut.id)}
    )
    |> Repo.all()
  end

  @doc "How many honor tags exist (the dashboard tile's count)."
  def honor_tags_count do
    Repo.aggregate(from(t in Tag.not_merged(), where: t.honor?), :count)
  end

  @doc """
  Declares `name` an honor tag from the admin "Honor tags" page — the one-step
  create the buried create-then-edit flow replaces. Create-or-flip, with a guard
  on the one dangerous case:

    * no such tag yet → create it flagged honor → `{:ok, tag}`
    * the tag exists and is already honor → `{:ok, tag}` (idempotent)
    * it exists, is not honor, and **no one holds it** → safe to flip → `{:ok, tag}`
    * it exists, is not honor, and **members already hold it** →
      `{:error, :has_holders, tag}` so the caller can route the admin to the
      edit form's retroactive-lock warning instead of silently locking holders
    * a blank or multi-word name → `{:error, changeset}`

  Ordinary member tags may contain spaces ("Ruby on Rails"), but an honor tag is
  a single-token reserved badge (the admin form promises "a single word with no
  spaces"), so a multi-word name is refused here even though the schema no longer
  forbids one.
  """
  def declare_honor_tag(name) when is_binary(name) do
    value = Tag.normalize_value(name)

    if String.contains?(value, " ") do
      changeset =
        %Tag{}
        |> Tag.changeset(%{"value" => value})
        |> Ecto.Changeset.add_error(:name, "must be a single word")

      {:error, changeset}
    else
      create_or_flip_honor_tag(value)
    end
  end

  defp create_or_flip_honor_tag(value) do
    case Tag.find_by_value(value) do
      nil ->
        %Tag{}
        |> Tag.changeset(%{"value" => value})
        |> Ecto.Changeset.put_change(:honor?, true)
        |> Repo.insert()

      %Tag{honor?: true} = tag ->
        {:ok, tag}

      %Tag{} = tag ->
        if tag_has_holders?(tag) do
          {:error, :has_holders, tag}
        else
          tag |> Ecto.Changeset.change(honor?: true) |> Repo.update()
        end
    end
  end

  defp tag_has_holders?(%Tag{} = tag) do
    Repo.exists?(from(ut in UserTag, where: ut.tag_id == ^tag.id))
  end

  # The search-engine bar for a tag page: how many publicly visible members
  # must carry a tag before its /tags/:slug page is worth a search index.
  # Below the bar (and with no public post) the page is a thin near-duplicate:
  # advertising all ~10K tags put most of them into Search Console as
  # "crawled - currently not indexed" and drowned the pages worth ranking.
  @min_indexable_members 2

  @doc "The member threshold behind `indexable_tags_query/0`."
  def min_indexable_members, do: @min_indexable_members

  @doc """
  The tags whose public page clears the search-engine bar: at least
  `min_indexable_members/0` publicly visible members (the same
  confirmed-and-not-hidden gate the tag page lists by), or at least one
  publicly visible post carrying the tag (`Posts.visible_tagged_posts_query/0`,
  the tag page's own posts gate). The sitemap advertises exactly this set and
  `VutuvWeb.TagController` noindexes every page below the bar, so the two can
  never drift apart.
  """
  def indexable_tags_query do
    import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]

    endorsed_enough =
      from(ut in UserTag,
        join: u in assoc(ut, :user),
        where: account_confirmed_row(u) and not account_hidden_row(u),
        group_by: ut.tag_id,
        having: count(ut.id) >= @min_indexable_members,
        select: ut.tag_id
      )

    posted = from([post_tag: pt] in Posts.visible_tagged_posts_query(), select: pt.tag_id)

    # `not_merged/1`: an alternative name is not a page of its own, so it never
    # enters the sitemap and its own URL is noindexed (issue #1338). It holds no
    # rows after a merge anyway, but an alias added by hand to a busy topic
    # would otherwise inherit the topic's numbers through the id it points at.
    from(t in Tag.not_merged(),
      where: t.id in subquery(endorsed_enough) or t.id in subquery(posted)
    )
  end

  @doc "Whether this one tag's page clears the bar (`indexable_tags_query/0`)."
  def indexable_tag?(%Tag{id: id}) do
    indexable_tags_query() |> where([t], t.id == ^id) |> Repo.exists?()
  end

  @doc """
  Given candidate tag slugs (the `#hashtags` in a Markdown body), returns a map
  from each written slug to the slug its link should point at — for those whose
  `/tags/:slug` page actually shows something: a real tag with **at least one
  visible member** (a confirmed, non-hidden user carries it, the same gate the
  tag page lists by) **or at least one publicly visible post** filed under it
  (`Posts.visible_tagged_posts_query/0`, the tag page's own posts gate). Powers
  the hashtag links `VutuvWeb.Markdown` writes; an unknown or empty tag is
  absent from the map, so it stays plain text.

  The two slugs differ exactly when the written one names an **alternative name**
  for a topic (issue #1338): `#rubyonrails` links straight to `/tags/ruby_on_rails`
  rather than to a URL that redirects there, and the gate is applied to the
  canonical tag, which is where the members and posts of an absorbed tag now sit.
  That is also why the answer is a map and not a set.

  The post arm is what keeps the link and the listing honest in both directions:
  a post is filed under the tag its own `#hashtag` names, so a tag nobody has on
  their profile but several posts carry is a page worth landing on. Without it a
  reader would meet a plain-text `#elixir` in a post that the elixir page lists.
  It is the same set `indexable_tags_query/0` calls worth indexing, at a
  threshold of one member rather than two — that bar asks whether a page
  deserves a crawler, this one only whether it deserves a click.

  One query per body (two arms of a union); an empty input skips the DB so the
  renderer's no-hashtag path stays query-free.
  """
  def linkable_slugs(slugs) when is_list(slugs) do
    import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]

    case slugs |> Enum.map(&String.downcase/1) |> Enum.uniq() do
      [] ->
        %{}

      normalized ->
        held =
          from(t in Tag,
            left_join: c in assoc(t, :merged_into),
            join: ut in UserTag,
            on: ut.tag_id == coalesce(c.id, t.id),
            join: u in assoc(ut, :user),
            where: t.slug in ^normalized,
            where: account_confirmed_row(u) and not account_hidden_row(u),
            select: %{slug: t.slug, target: coalesce(c.slug, t.slug)}
          )

        posted =
          from([post_tag: pt] in Posts.visible_tagged_posts_query(),
            join: t in Tag,
            on: pt.tag_id == coalesce(t.merged_into_id, t.id),
            left_join: c in assoc(t, :merged_into),
            where: t.slug in ^normalized,
            select: %{slug: t.slug, target: coalesce(c.slug, t.slug)}
          )

        from(row in subquery(union_all(held, ^posted)),
          distinct: true,
          select: {row.slug, row.target}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc """
  The ids of the tags `hashtags` names here — **existing tags only**, matched on
  the slug, which is exactly what `VutuvWeb.Markdown` links a `#hashtag` to.

  Feeds both hashtag filing paths: a member's post body
  (`Vutuv.Posts.create_post/2`) and a cached remote post
  (`Vutuv.Fediverse.Hashtags`). Neither mints a tag. For a member post that is
  merely conservative — the composer's own tag field is where a member deliberately
  names a new tag, and a typo in a body should not leave a page behind. For a
  remote post it is a rule: a table a stranger's server can extend is a table a
  stranger's server can flood with pages on our own domain.

  Matched case-insensitively on **name or slug**, the predicate
  `Tag.find_by_value/1` uses, so `#PostgreSQL` reaches the `postgresql` tag and a
  remote `#München` reaches the tag a member spelled that way (whose slug is
  transliterated and would never match on its own). Capped at
  `max_hashtags_per_body/0` so one hostile body cannot file itself under every
  tag on the site; an empty input skips the DB.
  """
  def tag_ids_for_hashtags([]), do: []

  def tag_ids_for_hashtags(hashtags) when is_list(hashtags) do
    names =
      hashtags
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.take(@max_hashtags_per_body)

    Repo.all(
      from(t in Tag,
        # A body that writes an alternative name files the post under the topic
        # (issue #1338), so `#rubyonrails` and `#RubyOnRails` land in the same
        # timeline. `distinct` because two written spellings can now resolve to
        # one tag, and `post_tags` has a unique index on (post_id, tag_id).
        left_join: c in assoc(t, :merged_into),
        where: fragment("lower(?)", t.name) in ^names or t.slug in ^names,
        distinct: true,
        select: coalesce(c.id, t.id)
      )
    )
  end

  @doc "How many `#hashtags` of one body are resolved to tags (see `tag_ids_for_hashtags/1`)."
  def max_hashtags_per_body, do: @max_hashtags_per_body

  # --- Tag follows (issue #872) --------------------------------------------
  #
  # A member following a tag is a private subscription that pulls the tag's posts
  # into their `/feed` (`Vutuv.Posts.feed_page/2` reads `followed_tag_ids/1` as a
  # third source) and leads the feed's "Who to follow" rail with people endorsed
  # for it. Silent: no notification, no public follower list — only the aggregate
  # `tag_follower_count/1`. `follow_tag/2` always sets `user_id` from the passed
  # session user, so a request can't forge someone else's subscription.

  @doc """
  Follows `tag` (a `%Tag{}` or a raw tag id) as `user` (issue #872). Idempotent:
  following a tag you already follow is a no-op that still returns `{:ok,
  tag_follow}` (the DB `ON CONFLICT` keeps a double-submit from raising). A
  non-UUID or unknown tag id comes back as `{:error, _}`, never a raise, so the
  controller can pass a request param straight through. Broadcasts
  `{:tag_follows_changed, %{}}` on the follower's activity topic so an open
  `/feed` refreshes its rails live.
  """
  def follow_tag(%User{} = user, %Tag{id: tag_id}), do: follow_tag(user, tag_id)

  def follow_tag(%User{} = user, tag_id) when is_binary(tag_id) do
    # After the insert the row is guaranteed to exist (a fresh insert, or an ON
    # CONFLICT no-op because it already did), so the get_by re-reads the
    # authoritative row to return; an unknown tag id trips the tag_id
    # foreign_key_constraint and comes back as {:error, changeset}. Both the
    # `nil` from a non-UUID id and a vanished row map to {:error, :invalid}.
    with tag_id when not is_nil(tag_id) <- Vutuv.UUIDv7.cast_or_nil(tag_id),
         {:ok, _} <- insert_tag_follow(user.id, tag_id),
         %TagFollow{} = follow <- Repo.get_by(TagFollow, user_id: user.id, tag_id: tag_id) do
      broadcast_tag_follows_changed(user.id)
      {:ok, follow}
    else
      nil -> {:error, :invalid}
      {:error, _} = error -> error
    end
  end

  defp insert_tag_follow(user_id, tag_id) do
    %TagFollow{}
    |> TagFollow.changeset(%{user_id: user_id, tag_id: tag_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :tag_id])
  end

  @doc """
  Unfollows a tag as `user`, by `%Tag{}` or a raw tag id. Idempotent: returns the
  number of rows removed (0 or 1), so unfollowing a tag you don't follow — or a
  double-submit — is a no-op, not a raise. A non-UUID id is treated as "nothing
  to remove". Broadcasts `{:tag_follows_changed, %{}}` when a row actually went.
  """
  def unfollow_tag(%User{} = user, %Tag{} = tag), do: unfollow_tag(user, tag.id)

  def unfollow_tag(%User{} = user, tag_id) do
    case Vutuv.UUIDv7.cast_or_nil(tag_id) do
      nil ->
        0

      tag_id ->
        {count, _} =
          from(tf in TagFollow, where: tf.user_id == ^user.id and tf.tag_id == ^tag_id)
          |> Repo.delete_all()

        if count > 0, do: broadcast_tag_follows_changed(user.id)
        count
    end
  end

  @doc "Whether `user` currently follows `tag` (a `%Tag{}` or a raw tag id)."
  def tag_followed?(%User{} = user, %Tag{} = tag), do: tag_followed?(user, tag.id)

  def tag_followed?(%User{} = user, tag_id) do
    Repo.exists?(from(tf in TagFollow, where: tf.user_id == ^user.id and tf.tag_id == ^tag_id))
  end

  @doc """
  The tags `user` follows, most-recently-followed first — the "Tags you follow"
  feed rail and the `/settings/followed_tags` list.
  """
  def followed_tags(%User{} = user) do
    Repo.all(
      from(tf in TagFollow,
        join: t in assoc(tf, :tag),
        where: tf.user_id == ^user.id,
        order_by: [desc: tf.inserted_at, desc: tf.id],
        select: t
      )
    )
  end

  @doc """
  The ids of the tags `user` follows — the set `Vutuv.Posts.feed_page/2` joins
  its third (followed-tag) source against. Accepts a `%User{}` or a raw user id.
  """
  def followed_tag_ids(%User{id: id}), do: followed_tag_ids(id)

  def followed_tag_ids(user_id) when is_binary(user_id) do
    Repo.all(from(tf in TagFollow, where: tf.user_id == ^user_id, select: tf.tag_id))
  end

  @doc """
  How many follow `tag` (the public aggregate on the tag page) — members and
  pages alike, since both are subscriptions to the same topic.
  """
  def tag_follower_count(%Tag{} = tag) do
    Repo.aggregate(from(tf in TagFollow, where: tf.tag_id == ^tag.id), :count)
  end

  @doc """
  A page follows a tag (issue #1336), so the topic reaches its own feed.
  Idempotent, like the member twin, and silent for the same reason: a tag has
  no owner to notify.
  """
  def follow_tag_as_organization(%Organization{} = page, tag_id) when is_binary(tag_id) do
    with tag_id when not is_nil(tag_id) <- Vutuv.UUIDv7.cast_or_nil(tag_id),
         {:ok, _} <- insert_organization_tag_follow(page.id, tag_id),
         %TagFollow{} = follow <-
           Repo.get_by(TagFollow, organization_id: page.id, tag_id: tag_id) do
      {:ok, follow}
    else
      nil -> {:error, :invalid}
      {:error, _} = error -> error
    end
  end

  def follow_tag_as_organization(%Organization{} = page, %Tag{id: id}),
    do: follow_tag_as_organization(page, id)

  defp insert_organization_tag_follow(organization_id, tag_id) do
    %TagFollow{}
    |> TagFollow.organization_changeset(%{organization_id: organization_id, tag_id: tag_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:organization_id, :tag_id])
  end

  @doc "Unfollows a tag as `page`. Idempotent; returns the number of rows removed."
  def unfollow_tag_as_organization(%Organization{} = page, %Tag{} = tag),
    do: unfollow_tag_as_organization(page, tag.id)

  def unfollow_tag_as_organization(%Organization{} = page, tag_id) do
    case Vutuv.UUIDv7.cast_or_nil(tag_id) do
      nil ->
        0

      tag_id ->
        {count, _} =
          from(tf in TagFollow,
            where: tf.organization_id == ^page.id and tf.tag_id == ^tag_id
          )
          |> Repo.delete_all()

        count
    end
  end

  @doc "Whether `page` currently follows `tag`."
  def tag_followed_by_organization?(%Organization{} = page, %Tag{} = tag),
    do: tag_followed_by_organization?(page, tag.id)

  def tag_followed_by_organization?(%Organization{} = page, tag_id) do
    Repo.exists?(
      from(tf in TagFollow, where: tf.organization_id == ^page.id and tf.tag_id == ^tag_id)
    )
  end

  @doc "The tags `page` follows, most-recently-followed first."
  def organization_followed_tags(%Organization{id: page_id}) do
    Repo.all(
      from(tf in TagFollow,
        join: t in assoc(tf, :tag),
        where: tf.organization_id == ^page_id,
        order_by: [desc: tf.inserted_at, desc: tf.id],
        select: t
      )
    )
  end

  @doc "The ids of the tags `page` follows — the set its feed's tag source joins against."
  def organization_followed_tag_ids(%Organization{id: page_id}) do
    Repo.all(from(tf in TagFollow, where: tf.organization_id == ^page_id, select: tf.tag_id))
  end

  @doc """
  Up to `limit` members endorsed for any tag `user` follows, most-endorsed
  first — the people half of issue #872, feeding the feed's "Who to follow"
  rail. Same visibility gate as `Tag.recommended_users/1` (unconfirmed /
  moderation-hidden accounts never surface) and the same narrow listing-row
  select; the viewer themselves is excluded here, the already-followed / blocked
  filtering stays at the rail call site (it already does it for the popular pool).
  Returns `[]` when the member follows no tags, so the rail falls back to the
  popular pool unchanged.
  """
  def people_for_followed_tags(%User{} = user, limit) do
    import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]

    case followed_tag_ids(user) do
      [] ->
        []

      tag_ids ->
        Repo.all(
          from(u in User,
            join: ut in assoc(u, :user_tags),
            left_join: e in assoc(ut, :endorsements),
            # Count only currently-visible endorsers (issue #783), the same gate
            # `Tag.most_endorsed_in_tag/2` applies: the test rides in the ON
            # clause, so a hidden/unconfirmed endorser leaves `endorser` NULL and
            # drops out of `count(endorser.id)`.
            left_join: endorser in assoc(e, :user),
            on: account_confirmed_row(endorser) and not account_hidden_row(endorser),
            where: ut.tag_id in ^tag_ids,
            where: u.id != ^user.id,
            where: account_confirmed_row(u) and not account_hidden_row(u),
            group_by: u.id,
            order_by: fragment("count(?) DESC", endorser.id),
            limit: ^limit,
            select: struct(u, ^User.listing_fields())
          )
        )
    end
  end

  # Tell `user`'s open feed (and any other subscriber) that their followed-tag
  # set changed, so the "Tags you follow" and "Who to follow" rails redraw with
  # no reload. `VutuvWeb.PostLive.Feed` listens for `:tag_follows_changed`;
  # everything else ignores it via its catch-all handle_info.
  defp broadcast_tag_follows_changed(user_id) do
    Vutuv.Activity.broadcast(user_id, {:tag_follows_changed, %{}})
  end

  @doc """
  Endorse a user's tag. The chokepoint for endorsements: besides inserting the
  row it pushes the live in-app notification to the tag's owner, so all
  endorsement paths must come through here (not a raw `Repo.insert`).
  """
  def create_endorsement(attrs) do
    if endorsement_target_honor?(attrs) do
      # An honor tag is an authoritative badge, not a peer vouch, so it
      # is not endorsable. The profile hides the pill; this guards a crafted
      # request that reaches the chokepoint anyway.
      {:error, :honor}
    else
      result = %UserTagEndorsement{} |> UserTagEndorsement.changeset(attrs) |> Repo.insert()

      with {:ok, endorsement} <- result do
        # notify_endorsement preloaded the owner already, so reuse the id it
        # returns for the live-count broadcast instead of re-querying it.
        broadcast_endorsement_changed(notify_endorsement(endorsement), endorsement.user_tag_id)
      end

      result
    end
  end

  defp endorsement_target_honor?(attrs) do
    user_tag_id = Map.get(attrs, :user_tag_id) || Map.get(attrs, "user_tag_id")

    is_binary(user_tag_id) and
      Repo.exists?(
        from(ut in UserTag,
          join: t in assoc(ut, :tag),
          where: ut.id == ^user_tag_id and t.honor?
        )
      )
  end

  @doc """
  Removes `user_id`'s endorsement of `user_tag_id`. Returns the number of rows
  deleted (0 or 1), so an undo of an endorsement that is already gone is a
  no-op rather than a raise (the profile's upvote pill toggles idempotently).
  """
  def delete_endorsement(user_tag_id, user_id) do
    {count, _} =
      from(e in UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id and e.user_id == ^user_id
      )
      |> Repo.delete_all()

    if count > 0 do
      owner_id = Repo.one(from(ut in UserTag, where: ut.id == ^user_tag_id, select: ut.user_id))
      broadcast_endorsement_changed(owner_id, user_tag_id)
    end

    count
  end

  @doc "Whether `user_id` currently endorses `user_tag_id`."
  def endorsed?(user_tag_id, user_id) do
    Repo.exists?(
      from(e in UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id and e.user_id == ^user_id
      )
    )
  end

  @doc """
  Number of *currently-visible* endorsers of `user_tag_id` (the public count
  shown on the upvote pill). Goes through `UserTagEndorsement.visible/1`, so a
  hidden or never-activated endorser never inflates the tally (issue #783).
  """
  def count_visible_endorsements(user_tag_id) do
    UserTagEndorsement.visible()
    |> where([e], e.user_tag_id == ^user_tag_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  One page of the *currently-visible* endorsers of `user_tag`, newest first.

  Backs the public endorser list (`/:slug/tags/:tag/endorsers`, the profile
  Tags popover's "and N more" link). Goes through
  `UserTagEndorsement.visible_with_endorser/1`, so hidden / unconfirmed
  endorsers are neither listed nor counted (issue #783), and is offset
  paginated by `Vutuv.Pages.paginate/3` like the follower / connection lists.
  The list is sortable from `params`: `"sort"` is one of `name` (last name
  then first name), `username` (the `username`) or `date` (the endorsement
  itself), and `"dir"` is `"asc"`/`"desc"`. Default is `date` descending —
  newest endorser first — and `e.id` (a time-ordered UUID v7) is the stable
  tiebreaker for every sort. Offset paginated at `endorsers_per_page/0` (a
  denser page than the site-wide default, so a long list actually paginates).

  Returns `%{users: [...], total: total, endorsed_at: %{user_id =>
  inserted_at}, sort: sort, dir: dir}` — `endorsed_at` carries when each
  listed endorser cast their vote (the per-row timestamp); `sort`/`dir` are
  the normalized values the page renders its sort controls from.
  """
  def endorsers_page(%UserTag{} = user_tag, params) do
    total = count_visible_endorsements(user_tag.id)
    {sort, dir} = endorser_sort(params)

    endorsements =
      UserTagEndorsement.visible_with_endorser()
      |> where([e], e.user_tag_id == ^user_tag.id)
      |> endorser_order(sort, dir)
      |> Vutuv.Pages.paginate(params, total, @endorsers_per_page)
      |> Repo.all()

    %{
      users: Enum.map(endorsements, & &1.user),
      total: total,
      endorsed_at: Map.new(endorsements, &{&1.user_id, &1.inserted_at}),
      sort: sort,
      dir: dir
    }
  end

  @doc "Rows per page of the endorsers list (shared by the query and the pager)."
  def endorsers_per_page, do: @endorsers_per_page

  # Normalize the sort params, defaulting to newest-endorser-first.
  defp endorser_sort(params) do
    sort = if params["sort"] in @endorser_sorts, do: params["sort"], else: "date"
    dir = if params["dir"] in ~w(asc desc), do: params["dir"], else: default_dir(sort)
    {sort, dir}
  end

  defp default_dir("date"), do: "desc"
  defp default_dir(_sort), do: "asc"

  # Order the endorsements; `u` is the endorser joined in by visible_with_endorser/0.
  # e.id (UUID v7 = creation order) is the stable tiebreaker on every sort.
  defp endorser_order(query, "name", dir) do
    d = dir_atom(dir)
    order_by(query, [e, u], [{^d, u.last_name}, {^d, u.first_name}, desc: e.id])
  end

  defp endorser_order(query, "username", dir) do
    d = dir_atom(dir)
    order_by(query, [e, u], [{^d, u.username}, desc: e.id])
  end

  defp endorser_order(query, "date", dir) do
    order_by(query, [e], [{^dir_atom(dir), e.id}])
  end

  defp dir_atom("asc"), do: :asc
  defp dir_atom(_dir), do: :desc

  defp notify_endorsement(endorsement) do
    %{user_tag: %{user_id: owner_id, tag: tag}} =
      Repo.preload(endorsement, user_tag: :tag)

    # Endorsing your own tag is possible but not news.
    if owner_id != endorsement.user_id do
      endorser = Repo.get(Vutuv.Accounts.User, endorsement.user_id)
      Vutuv.Activity.notify_endorsement(owner_id, endorser, tag.name)
    end

    owner_id
  end

  # Tell the tag owner's open profile to re-render the affected pill's count and
  # roster live, so an endorse / unendorse shows even on a different page or when
  # made by another member. `VutuvWeb.UserProfileLive` listens for
  # `:endorsement_changed`; other subscribers ignore it (catch-all handle_info).
  defp broadcast_endorsement_changed(owner_id, user_tag_id) do
    Vutuv.Activity.broadcast(owner_id, {:endorsement_changed, user_tag_id})
  end

  @doc """
  One-time cleanup of legacy whitespace in tag names (issue #847).

  vutuv's "a tag is a single token, no spaces" rule postdates the original 2017
  data, so thousands of tags still carry spaces in their display `name`. This
  reconciles that legacy data with the rule **without underscoring a legitimate
  multi-word name** — "Ruby on Rails" stays "Ruby on Rails", its already
  spaceless slug `ruby_on_rails` staying the stable link key. It does two
  things:

    * **Merges** the whitespace-only duplicate groups — two tags that differ
      only in spacing / underscores / case (" Datacenter" vs "Datacenter",
      "Phoenix Framework" vs "phoenix_framework") — into one survivor, moving
      every `user_tag` and endorsement across and deleting the duplicate. The
      survivor is the tag with the most holders (ties: the cleaner name, then
      the oldest), and its own name is trimmed too.
    * **Trims** stray leading/trailing and doubled whitespace from every other
      name ("performance testing " → "performance testing").

  Slugs are already spaceless and unique, so they are never touched. Returns
  `{merged_tags_deleted, names_trimmed}`. Idempotent — a second run is a no-op —
  and empty on a fresh / test database, so the real work happens only against
  production data.
  """
  def normalize_legacy_tag_whitespace do
    merged = merge_whitespace_duplicate_tags()
    trimmed = trim_tag_name_whitespace()
    {merged, trimmed}
  end

  # Group every tag by a whitespace/underscore/case-insensitive identity key and
  # act only on groups with more than one member where at least one name carries
  # whitespace (so pure-underscore duplicates stay out of scope). Returns the
  # number of duplicate tags deleted.
  defp merge_whitespace_duplicate_tags do
    from(t in Tag, select: {t.id, t.name})
    |> Repo.all()
    |> Enum.group_by(fn {_id, name} -> collision_key(name) end)
    |> Enum.filter(fn {_key, members} ->
      length(members) > 1 and Enum.any?(members, fn {_id, name} -> whitespace?(name) end)
    end)
    |> Enum.reduce(0, fn {_key, members}, deleted -> deleted + merge_group(members) end)
  end

  defp merge_group(members) do
    ranked =
      Enum.map(members, fn {id, name} ->
        %{id: id, name: name, holders: holder_count(id), clean?: clean_name?(name)}
      end)

    # Smallest tuple wins: -holders => most holders first; a clean name beats a
    # whitespace-marred one; then the oldest id (UUID v7 sorts by creation time).
    survivor =
      Enum.min_by(ranked, fn m -> {-m.holders, if(m.clean?, do: 0, else: 1), m.id} end)

    duplicates = Enum.reject(ranked, &(&1.id == survivor.id))
    Enum.each(duplicates, &merge_tag_into(&1.id, survivor.id))
    normalize_tag_name(survivor.id, survivor.name)
    length(duplicates)
  end

  # Move a duplicate tag's members (and their endorsements) onto the survivor,
  # then delete the now-orphaned duplicate. Repointing happens *before* the
  # delete: `user_tags.tag_id` cascades on delete, so deleting first would wipe
  # the very rows we are trying to preserve.
  defp merge_tag_into(dup_id, survivor_id) do
    for ut <- Repo.all(from(ut in UserTag, where: ut.tag_id == ^dup_id)) do
      target =
        Repo.one(
          from(s in UserTag,
            where: s.user_id == ^ut.user_id and s.tag_id == ^survivor_id,
            select: s.id
          )
        )

      if target do
        # The member already holds the survivor tag, so this row would violate
        # the (user_id, tag_id) unique index. Move its endorsements onto the
        # surviving user_tag and drop the duplicate (leftover endorsements from
        # endorsers who already endorse the survivor cascade away with it).
        move_endorsements(ut.id, target)
        Repo.delete_all(from(d in UserTag, where: d.id == ^ut.id))
      else
        Repo.update_all(from(d in UserTag, where: d.id == ^ut.id),
          set: [tag_id: survivor_id]
        )
      end
    end

    Repo.delete_all(from(t in Tag, where: t.id == ^dup_id))
  end

  defp move_endorsements(from_user_tag_id, to_user_tag_id) do
    already =
      Repo.all(
        from(e in UserTagEndorsement, where: e.user_tag_id == ^to_user_tag_id, select: e.user_id)
      )

    Repo.update_all(
      from(e in UserTagEndorsement,
        where: e.user_tag_id == ^from_user_tag_id and e.user_id not in ^already
      ),
      set: [user_tag_id: to_user_tag_id]
    )
  end

  # Trim stray whitespace from every tag name the merge pass did not already
  # rewrite. Returns the number of names changed.
  defp trim_tag_name_whitespace do
    from(t in Tag, select: {t.id, t.name})
    |> Repo.all()
    |> Enum.reduce(0, fn {id, name}, trimmed ->
      trimmed + normalize_tag_name(id, name)
    end)
  end

  # Rewrite the tag's name to its trimmed, single-spaced form when it differs;
  # returns 1 if a row was changed, 0 otherwise.
  defp normalize_tag_name(id, name) do
    normalized = normalize_whitespace(name)

    if normalized == name do
      0
    else
      Repo.update_all(from(t in Tag, where: t.id == ^id), set: [name: normalized])
      1
    end
  end

  # Trim and collapse internal whitespace runs to a single space — keeps the
  # words, never underscores.
  defp normalize_whitespace(name), do: name |> String.trim() |> String.replace(~r/\s+/u, " ")

  # The identity key duplicate detection groups by: trim, fold every run of
  # whitespace *or* underscore to one underscore, downcase. So "Phoenix
  # Framework", "phoenix_framework" and " phoenix framework " all collide.
  defp collision_key(name),
    do: name |> String.trim() |> String.replace(~r/[\s_]+/u, "_") |> String.downcase()

  defp whitespace?(name), do: Regex.match?(~r/\s/u, name)
  defp clean_name?(name), do: normalize_whitespace(name) == name

  defp holder_count(tag_id),
    do: Repo.aggregate(from(ut in UserTag, where: ut.tag_id == ^tag_id), :count)

  @doc """
  One-time cleanup of the legacy tags whose own name carries a comma.

  A comma is what separates two tags when a member types a batch — that is the
  whole of `parse_tag_names/1`'s rule — so a tag *named* "Linux, Debian, Ubuntu,
  CentOS" is a pasted list from before the rule existed: one row standing in for
  four topics, matching none of them in a search, and filed under a slug nobody
  would ever type. There is no reader these serve, so they go rather than get
  split: guessing which of four topics a member meant to claim is a decision
  only that member can make, and they can retype the ones they want.

  See `delete_tags_matching/1` for what a deletion takes with it and what stops
  it. Returns rows deleted per table.
  """
  def delete_legacy_comma_tags do
    delete_tags_matching(from(t in Tag, where: like(t.name, "%,%")))
  end

  @doc """
  One-time cleanup of the legacy tags whose name runs to #{@overlong_tag_length}
  characters or more.

  Past roughly this length a tag name stops being a topic and starts being a
  sentence — a line lifted out of a job ad or a skills list, pasted whole into
  the tag field. Two things in the data say so plainly: the longest name in the
  table is 41 characters, and 159 names sit at exactly 40 with 140 of those
  ending in a literal "...", the signature of a legacy importer that truncated
  at 40 and appended an ellipsis. A name cut off mid-word names nothing, matches
  no search, and cannot be typed by anyone hoping to land on it.

  The threshold is deliberately generous: real compound topics
  ("Softwareentwicklung", "Projektmanagement") sit well under it, so this takes
  the phrases and leaves the vocabulary. A member who wants a long name back can
  retype it.

  See `delete_tags_matching/1` for what a deletion takes with it and what stops
  it. Returns rows deleted per table.
  """
  def delete_legacy_overlong_tags do
    delete_tags_matching(
      from(t in Tag, where: fragment("char_length(?) >= ?", t.name, ^@overlong_tag_length))
    )
  end

  @doc """
  Deletes the tags nothing points at any more.

  A tag row is not the thing members see — the chips on a profile, the posts on
  `/tags/:slug` and the follow button are all rows in other tables that name it.
  Once the last of those is gone the tag is a name no surface can reach, and the
  most common way that happens is an account leaving and taking its `user_tags`
  with it.

  "Nobody holds it" is deliberately **not** the test. A tag with no holder can
  still be the chip under somebody's post, the `#hashtag` in a sentence, a
  subscription, or the audience rule of a newsletter group. The test is that no
  row in *any* table referencing `tags` names it, and the tables are read from
  the live foreign keys, so one added later is included without an edit here.

  Returns rows deleted per table (only `tags` can be non-zero — a tag nothing
  references has, by definition, nothing to cascade). Idempotent.
  """
  def delete_orphaned_tags do
    delete_tags_matching(orphaned_tags_query())
  end

  # `WHERE NOT EXISTS (…)` once per referencing table. The table and column names
  # come from the catalog, never from user input, but Ecto rightly refuses an
  # interpolated `fragment/1`, so the condition is run as its own statement and
  # the ids it returns become an ordinary query.
  defp orphaned_tags_query do
    conditions =
      "tags"
      |> foreign_keys_to()
      |> Enum.map_join(" AND ", fn %{table: table, column: column} ->
        "NOT EXISTS (SELECT 1 FROM #{table} ref WHERE ref.#{column} = t.id)"
      end)

    %{rows: rows} = Repo.query!("SELECT t.id::text FROM tags t WHERE #{conditions}", [])

    from(t in Tag, where: t.id in ^List.flatten(rows))
  end

  @doc """
  Deletes every tag `query` selects, and everything that hung off it.

  A tag goes together with the rows that existed only to tie something to it —
  the `user_tags` and their endorsements, the `post_tags`, `post_hashtags`,
  `fediverse_post_tags`, `job_posting_tags` and `tag_follows`. What sits on the
  far side of those join rows is untouched: a member keeps their account, a post
  keeps its body, and both simply lose the tag.

  The fan-out is walked from the live foreign keys rather than a list written
  here, so a table added to the schema after this was written is still accounted
  for. Anything that would **survive** the delete holding a nulled pointer stops
  the cleanup with a raise instead: today that is `newsletter_groups.tag_id`
  (ON DELETE SET NULL), where nulling would quietly widen an audience from
  "members holding this tag" to "every member" — not a call a cleanup gets to
  make. Postgres itself blocks any reference it cannot resolve, so the delete is
  either complete or it does not happen.

  Returns rows deleted per table. Idempotent, and a no-op on a fresh or test
  database, so the real work only ever happens against production data.
  """
  def delete_tags_matching(query) do
    {:ok, counts} = Repo.transaction(fn -> delete_matching_tags(query) end)
    counts
  end

  defp delete_matching_tags(query) do
    # Resolve the doomed ids up front so the guard below and the delete itself
    # are provably the same set of tags, rather than two evaluations of one
    # predicate with a window between them.
    doomed = Repo.all(from(t in query, select: t.id))
    {cascading, retaining} = tag_delete_fanout()
    Enum.each(retaining, &refuse_dangling_reference!(&1, doomed))

    before = row_counts(cascading)
    Repo.delete_all(from(t in Tag, where: t.id in ^doomed))
    remaining = row_counts(cascading)

    Map.new(cascading, fn table -> {table, before[table] - remaining[table]} end)
  end

  # Every table a `tags` delete empties, found by following the foreign keys
  # that cascade — and transitively their own, so a second-order row like a
  # `user_tag_endorsements` hanging off a deleted `user_tags` is counted as
  # well. Returns `{cascading_tables, retaining_refs}`: the tables whose rows go
  # with the tag, and the references that would outlive it.
  defp tag_delete_fanout, do: walk_cascade(["tags"], MapSet.new(["tags"]), [])

  defp walk_cascade([], cascading, retaining), do: {MapSet.to_list(cascading), retaining}

  defp walk_cascade([table | rest], cascading, retaining) do
    {cascades, retains} = Enum.split_with(foreign_keys_to(table), &(&1.on_delete == "c"))

    fresh =
      cascades
      |> Enum.map(& &1.table)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(cascading, &1))

    walk_cascade(rest ++ fresh, MapSet.union(cascading, MapSet.new(fresh)), retaining ++ retains)
  end

  # The foreign keys pointing AT `table`, straight from the catalog:
  # `confdeltype` is the ON DELETE rule ("c" cascade, "n" set null, "a" no
  # action, "r" restrict, "d" set default).
  defp foreign_keys_to(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.conrelid::regclass::text, a.attname, c.confdeltype
        FROM pg_constraint c
        JOIN unnest(c.conkey) AS k(attnum) ON true
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        WHERE c.contype = 'f' AND c.confrelid = $1::text::regclass
        """,
        [table]
      )

    Enum.map(rows, fn [child, column, on_delete] ->
      %{parent: table, table: child, column: column, on_delete: on_delete}
    end)
  end

  # A reference straight to `tags` that does not cascade: the row survives the
  # delete, so the cleanup may only proceed while no such row actually points at
  # a doomed tag. Fail closed — a pointer we would blank is a product decision.
  #
  # `$1::text[]::uuid[]` and not a bare `::uuid[]`: Postgres reports the
  # parameter type of the latter as `uuid[]`, and Postgrex then demands the raw
  # 16-byte form, so the readable `019f…` strings `Repo.all` returns would raise
  # an EncodeError. Casting from text hands Postgres the strings to parse.
  defp refuse_dangling_reference!(%{parent: "tags", table: table, column: column}, doomed) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM #{table} WHERE #{column} = ANY($1::text[]::uuid[])",
        [doomed]
      )

    if count > 0 do
      raise """
      #{count} #{table} row(s) reference a doomed tag through #{table}.#{column}, \
      which does not cascade: deleting the tags would leave those rows behind \
      pointing at nothing. Decide what should happen to them first — for \
      #{table}.#{column} that means re-pointing or deleting them by hand — then \
      run the cleanup again.\
      """
    end
  end

  # The same hazard one level down: a table that outlives the cascade holding a
  # blanked pointer into it. None exists today, so this is a tripwire for a
  # foreign key added between now and the day this runs, and refusing outright
  # is the honest answer — which rows are doomed depends on the whole cascade
  # path, and no cleanup should guess at it.
  defp refuse_dangling_reference!(%{parent: parent, table: table, column: column}, _doomed) do
    raise """
    #{table}.#{column} references #{parent}, which this cleanup deletes from, \
    and it does not cascade. That foreign key postdates the cleanup; work out \
    what those rows should become before deleting these tags.\
    """
  end

  defp row_counts(tables) do
    Map.new(tables, fn table ->
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      {table, count}
    end)
  end
end
