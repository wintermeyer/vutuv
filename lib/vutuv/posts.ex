defmodule Vutuv.Posts do
  @moduledoc """
  The Posts context: markdown posts with images, tags and deny-model
  audiences.

  **Visibility is deny-based.** A post with no denials is public (crawlable,
  visible logged-out). Each `Vutuv.Posts.PostDenial` excludes the readers
  matching one target (group / single user / wildcard); matching *any* denial
  excludes the reader. Three invariants live here, not in data:

    * the author always sees their own posts;
    * **any** denial also closes anonymous access — a logged-out reader
      cannot be proven not-denied;
    * group membership is evaluated live at read time.

  All four read paths (feed, profile, permalink, image proxy) must go through
  `visible_to?/2` or the composable `scope_visible/2` — never filter by hand.

  **Permalinks** are `/:slug/:year/:month/:day/:seq`: `published_on` is the
  UTC date at insert time and `seq` a per-author-per-day counter, generated
  under a unique index with retry (`create_post/2`), and never changed by
  edits.

  **Images** upload eagerly while composing (`create_pending_image/3`), so
  inline markdown can reference them before the post exists; submit attaches
  them (`image_ids`). Unattached leftovers are swept after a day.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.PostImageStore
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostTag
  alias Vutuv.Repo
  alias Vutuv.Social.Connection
  alias Vutuv.Social.Group
  alias Vutuv.Tags.Tag

  @default_feed_limit 20
  @default_profile_limit 3
  @seq_attempts 3
  @pending_max_age_hours 24
  @max_tags 5

  def max_images_per_post, do: Keyword.fetch!(config(), :max_per_post)
  def max_image_filesize, do: Keyword.fetch!(config(), :max_filesize)
  def max_tags_per_post, do: @max_tags
  defp config, do: Application.fetch_env!(:vutuv, :post_images)

  ## Creating / updating / deleting

  @doc """
  Creates a post for `author`.

  Accepted attrs (atom or string keys):

    * `:body` — markdown, at most `Post.max_body_length/0` chars; may be
      blank when images are attached
    * `:denials` — list of `%{"group_id" => id}` / `%{"denied_user_id" => id}`
      / `%{"wildcard" => w}` maps (see `Vutuv.Posts.PostDenial`)
    * `:tags` — comma-separated string or list of tag names (find-or-create,
      case-insensitive; invalid values are skipped, at most
      `max_tags_per_post/0` are kept)
    * `:image_ids` — pending image ids of the author, in display order

  Returns `{:ok, post}` (preloaded), `{:error, changeset}`,
  `{:error, :invalid_denials}`, `{:error, :invalid_images}` or
  `{:error, :too_many_images}`. Broadcasts `{:new_post, %{post_id:,
  author_id:}}` to the author's and every follower's activity topic.
  """
  def create_post(%User{} = author, attrs) do
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with {:ok, denials} <- normalize_denials(author.id, fetch(attrs, :denials) || []),
         :ok <- check_image_count(image_ids),
         {:ok, changeset} <- build_changeset(%Post{user_id: author.id}, attrs, denials, image_ids) do
      case insert_with_seq(author, changeset, image_ids, @seq_attempts) do
        {:ok, post} ->
          post = preload_post(post)
          broadcast_new_post(post)
          {:ok, post}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Updates a post: body, denials, tags and the attached-image set are replaced
  by what `attrs` carries (same keys as `create_post/2`). Detached images are
  deleted, rows and files. The permalink coordinates never change.
  """
  def update_post(%Post{} = post, attrs) do
    post = Repo.preload(post, [:denials, :post_tags, :images])
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with {:ok, denials} <- normalize_denials(post.user_id, fetch(attrs, :denials) || []),
         :ok <- check_image_count(image_ids),
         {:ok, changeset} <- build_changeset(post, attrs, denials, image_ids) do
      removed = Enum.reject(post.images, &(&1.id in image_ids))
      run_update(changeset, removed, image_ids)
    end
  end

  defp run_update(changeset, removed, image_ids) do
    case Repo.transaction(fn -> apply_update!(changeset, removed, image_ids) end) do
      {:ok, updated} ->
        # Only after the commit: a rolled-back update must not lose files.
        Enum.each(removed, &PostImageStore.delete(&1.token))
        {:ok, preload_post(updated)}

      {:error, _} = error ->
        error
    end
  end

  defp apply_update!(changeset, removed, image_ids) do
    case Repo.update(changeset) do
      {:ok, updated} ->
        if removed != [] do
          Repo.delete_all(from(i in PostImage, where: i.id in ^Enum.map(removed, & &1.id)))
        end

        attach_images!(updated, image_ids)
        updated

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc "Deletes a post including its image files."
  def delete_post(%Post{} = post) do
    post = Repo.preload(post, :images)

    case Repo.delete(post) do
      {:ok, deleted} ->
        Enum.each(post.images, &PostImageStore.delete(&1.token))
        {:ok, deleted}

      {:error, _} = error ->
        error
    end
  end

  # Body + denials + tags in one changeset; images attach separately (they
  # are pre-existing rows, not nested params).
  defp build_changeset(post_or_struct, attrs, denials, image_ids) do
    tag_ids = attrs |> fetch(:tags) |> parse_tag_values() |> tag_ids_for()

    changeset =
      post_or_struct
      |> Post.changeset(%{body: to_string(fetch(attrs, :body) || "")})
      |> Ecto.Changeset.put_assoc(:denials, Enum.map(denials, &struct(PostDenial, &1)))
      |> Ecto.Changeset.put_assoc(:post_tags, Enum.map(tag_ids, &%PostTag{tag_id: &1}))
      |> require_content(image_ids)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp require_content(changeset, image_ids) do
    body = Ecto.Changeset.get_field(changeset, :body) || ""

    if String.trim(body) == "" and image_ids == [] do
      Ecto.Changeset.add_error(changeset, :body, "can't be blank")
    else
      changeset
    end
  end

  # The per-day counter races under a unique index: compute max+1, insert,
  # and on a seq collision recompute and retry (each attempt in its own
  # transaction, so the aborted insert never poisons the next one).
  defp insert_with_seq(_author, _changeset, _image_ids, 0), do: {:error, :seq_conflict}

  defp insert_with_seq(author, changeset, image_ids, attempts) do
    today = Date.utc_today()

    result =
      Repo.transaction(fn ->
        seq = next_seq(author.id, today)

        changeset
        |> Ecto.Changeset.change(published_on: today, seq: seq)
        |> Repo.insert()
        |> case do
          {:ok, post} ->
            attach_images!(post, image_ids)
            post

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, post} ->
        {:ok, post}

      {:error, %Ecto.Changeset{errors: errors} = errored} ->
        if Keyword.has_key?(errors, :seq) do
          # Lost the per-day counter race — recompute and retry with the
          # original (pre-insert) changeset.
          insert_with_seq(author, changeset, image_ids, attempts - 1)
        else
          {:error, errored}
        end

      {:error, _} = error ->
        error
    end
  end

  defp next_seq(user_id, date) do
    max =
      Repo.one(
        from(p in Post,
          where: p.user_id == ^user_id and p.published_on == ^date,
          select: max(p.seq)
        )
      )

    (max || 0) + 1
  end

  # Claims each image row for the post (ownership and pending state are
  # enforced by the WHERE, so a tampered id rolls the whole insert back).
  defp attach_images!(%Post{} = post, image_ids) do
    now = NaiveDateTime.utc_now(:second)

    image_ids
    |> Enum.with_index()
    |> Enum.each(fn {id, position} ->
      {count, _} =
        Repo.update_all(
          from(i in PostImage,
            where:
              i.id == ^id and i.user_id == ^post.user_id and
                (is_nil(i.post_id) or i.post_id == ^post.id)
          ),
          set: [post_id: post.id, position: position, updated_at: now]
        )

      if count != 1, do: Repo.rollback(:invalid_images)
    end)
  end

  defp check_image_count(image_ids) do
    if length(image_ids) > max_images_per_post(), do: {:error, :too_many_images}, else: :ok
  end

  ## Denials

  # Validates and normalizes the denial list into attr maps for PostDenial
  # structs. Groups must belong to the author; you cannot deny yourself;
  # wildcards must be known. Duplicates collapse.
  defp normalize_denials(author_id, denials) when is_list(denials) do
    denials
    |> Enum.reduce_while({:ok, []}, fn denial, {:ok, acc} ->
      case normalize_denial(author_id, denial) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        :error -> {:halt, {:error, :invalid_denials}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_denials(_author_id, _other), do: {:error, :invalid_denials}

  defp normalize_denial(author_id, denial) when is_map(denial) do
    targets = [
      group_id: denial |> fetch(:group_id) |> parse_id(),
      denied_user_id: denial |> fetch(:denied_user_id) |> parse_id(),
      wildcard: fetch(denial, :wildcard)
    ]

    # Exactly one target per denial (mirrors the DB check constraint).
    case Enum.reject(targets, fn {_key, value} -> is_nil(value) end) do
      [target] -> validate_denial_target(author_id, target)
      _ -> :error
    end
  end

  defp normalize_denial(_author_id, _other), do: :error

  defp validate_denial_target(author_id, {:group_id, group_id}) do
    case Repo.get(Group, group_id) do
      %Group{user_id: ^author_id} -> {:ok, %{group_id: group_id}}
      _ -> :error
    end
  end

  defp validate_denial_target(author_id, {:denied_user_id, denied_user_id}) do
    if denied_user_id != author_id &&
         Repo.exists?(from(u in User, where: u.id == ^denied_user_id)) do
      {:ok, %{denied_user_id: denied_user_id}}
    else
      :error
    end
  end

  defp validate_denial_target(_author_id, {:wildcard, wildcard}) do
    if wildcard in PostDenial.wildcards(), do: {:ok, %{wildcard: wildcard}}, else: :error
  end

  ## Visibility

  @doc """
  Whether `viewer` (a `%User{}` or `nil` for anonymous) may see `post`.

  The single source of truth for post access — the permalink page, the
  image proxy and the live-feed pill all call this. List queries use the
  equivalent `scope_visible/2`.
  """
  def visible_to?(%Post{user_id: author_id}, %User{id: author_id}), do: true

  def visible_to?(%Post{} = post, nil) do
    # Anonymous readers see a post only when it has no denials at all.
    not restricted?(post)
  end

  def visible_to?(%Post{} = post, %User{id: viewer_id}) do
    not Repo.exists?(denial_match_query(post.id, post.user_id, viewer_id))
  end

  # All denial rows of the post that match this viewer (union semantics).
  defp denial_match_query(post_id, author_id, viewer_id) do
    from(d in PostDenial,
      where: d.post_id == ^post_id,
      where:
        d.denied_user_id == ^viewer_id or
          d.wildcard == "everyone" or
          (d.wildcard == "non_followers" and
             fragment(
               "NOT EXISTS (SELECT 1 FROM connections c WHERE c.follower_id = ? AND c.followee_id = ?)",
               ^viewer_id,
               ^author_id
             )) or
          (d.wildcard == "non_followees" and
             fragment(
               "NOT EXISTS (SELECT 1 FROM connections c WHERE c.follower_id = ? AND c.followee_id = ?)",
               ^author_id,
               ^viewer_id
             )) or
          (not is_nil(d.group_id) and
             fragment(
               """
               EXISTS (SELECT 1 FROM memberships m
                       JOIN connections c ON c.id = m.connection_id
                       WHERE m.group_id = ? AND c.follower_id = ? AND c.followee_id = ?)
               """,
               d.group_id,
               ^author_id,
               ^viewer_id
             ))
    )
  end

  @doc """
  Narrows a `Post` query to what `viewer` may see — the SQL twin of
  `visible_to?/2`. Composable: `from(p in Post) |> scope_visible(viewer)`.
  """
  def scope_visible(query, nil) do
    from(p in query,
      where: fragment("NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = ?)", p.id)
    )
  end

  def scope_visible(query, %User{id: viewer_id}) do
    from(p in query,
      where:
        p.user_id == ^viewer_id or
          fragment(
            """
            NOT EXISTS (
              SELECT 1 FROM post_denials d
              WHERE d.post_id = ?
                AND (
                  d.denied_user_id = ?
                  OR d.wildcard = 'everyone'
                  OR (d.wildcard = 'non_followers' AND NOT EXISTS (
                        SELECT 1 FROM connections c
                        WHERE c.follower_id = ? AND c.followee_id = ?))
                  OR (d.wildcard = 'non_followees' AND NOT EXISTS (
                        SELECT 1 FROM connections c
                        WHERE c.follower_id = ? AND c.followee_id = ?))
                  OR (d.group_id IS NOT NULL AND EXISTS (
                        SELECT 1 FROM memberships m
                        JOIN connections c ON c.id = m.connection_id
                        WHERE m.group_id = d.group_id
                          AND c.follower_id = ? AND c.followee_id = ?))
                )
            )
            """,
            p.id,
            ^viewer_id,
            ^viewer_id,
            p.user_id,
            p.user_id,
            ^viewer_id,
            p.user_id,
            ^viewer_id
          )
    )
  end

  @doc """
  Whether the post has any audience restriction. Restricted posts are
  noindexed and hidden from anonymous visitors.
  """
  def restricted?(%Post{denials: denials}) when is_list(denials), do: denials != []

  def restricted?(%Post{id: id}) do
    Repo.exists?(from(d in PostDenial, where: d.post_id == ^id))
  end

  ## Reading

  @doc """
  One page of `viewer`'s newsfeed: own posts plus posts of followed
  (validated) authors, visibility-filtered, newest first. Returns
  `%{entries:, more?:, next_cursor:}` — pass `cursor:` back for the next
  older page. Entries are preloaded for rendering.
  """
  def feed_page(%User{id: viewer_id} = viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_feed_limit)
    cursor = Keyword.get(opts, :cursor)

    followees = from(c in Connection, where: c.follower_id == ^viewer_id, select: c.followee_id)

    posts =
      from(p in Post,
        join: u in assoc(p, :user),
        where: p.user_id == ^viewer_id or p.user_id in subquery(followees),
        where: p.user_id == ^viewer_id or is_nil(u.validated?) or u.validated? == true,
        order_by: [desc: p.inserted_at, desc: p.id],
        limit: ^(limit + 1)
      )
      |> scope_visible(viewer)
      |> before_cursor(cursor)
      |> Repo.all()
      |> Repo.preload(post_preloads())

    entries = Enum.take(posts, limit)
    more? = length(posts) > limit

    %{entries: entries, more?: more?, next_cursor: if(more?, do: cursor_for(entries))}
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, %{at: at, id: id}) do
    where(query, [p], p.inserted_at < ^at or (p.inserted_at == ^at and p.id < ^id))
  end

  defp cursor_for(entries) do
    last = List.last(entries)
    %{at: last.inserted_at, id: last.id}
  end

  @doc """
  The newest posts of `author` that `viewer` may see (profile page section).
  """
  def profile_posts(%User{} = author, viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_profile_limit)

    author
    |> author_posts_query(viewer)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(post_preloads())
  end

  @doc "How many of `author`'s posts `viewer` may see (the \"View all\" label)."
  def count_author_posts(%User{} = author, viewer) do
    author |> author_posts_query(viewer) |> Repo.aggregate(:count)
  end

  @doc """
  One offset page of `author`'s posts visible to `viewer` — the author
  archive at `/:slug/posts` (browse-style pagination, like followers/tags).
  Returns `{posts, total}`.
  """
  def author_posts_page(%User{} = author, viewer, params) do
    query = author_posts_query(author, viewer)
    total = Repo.aggregate(query, :count)

    posts =
      query
      |> Vutuv.Pages.paginate(params, total)
      |> Repo.all()
      |> Repo.preload(post_preloads())

    {posts, total}
  end

  defp author_posts_query(%User{id: author_id}, viewer) do
    from(p in Post,
      where: p.user_id == ^author_id,
      order_by: [desc: p.inserted_at, desc: p.id]
    )
    |> scope_visible(viewer)
  end

  @doc "The permalink lookup: a preloaded post of `author`, or `nil`."
  def get_post(%User{id: author_id}, %Date{} = date, seq) when is_integer(seq) do
    from(p in Post,
      where: p.user_id == ^author_id and p.published_on == ^date and p.seq == ^seq
    )
    |> Repo.one()
    |> preload_post()
  end

  @doc "A preloaded post by id, or `nil` (live-feed pill, edit page)."
  def get_post(id) do
    Post |> Repo.get(id) |> preload_post()
  end

  defp preload_post(nil), do: nil
  defp preload_post(%Post{} = post), do: Repo.preload(post, post_preloads(), force: true)

  defp post_preloads do
    # denials with group/denied_user: the author-facing audience display
    # names them (never shown to other viewers).
    [
      :user,
      :images,
      denials: [:group, :denied_user],
      tags: from(t in Tag, order_by: t.name)
    ]
  end

  @doc """
  The root-relative permalink path, e.g. `/stefan/2026/06/05/0001`.
  Requires `:user` to be preloaded.
  """
  def path(%Post{user: %User{} = user, published_on: date} = post) do
    month = String.pad_leading(Integer.to_string(date.month), 2, "0")
    day = String.pad_leading(Integer.to_string(date.day), 2, "0")
    "/#{user.active_slug}/#{date.year}/#{month}/#{day}/#{Post.seq_string(post.seq)}"
  end

  ## Images

  @doc """
  Stores an eagerly-uploaded image (WebP versions + private original) and
  creates its pending row. Returns `{:ok, image}`, `{:error, :too_large}` or
  `{:error, :invalid_file}`.
  """
  def create_pending_image(%User{} = user, %Plug.Upload{} = upload) do
    create_pending_image(user, upload.path, upload.filename)
  end

  def create_pending_image(%User{} = user, path, filename) do
    if File.stat!(path).size > max_image_filesize() do
      {:error, :too_large}
    else
      token = PostImage.gen_token()

      case PostImageStore.store(path, filename, token) do
        {:ok, meta} ->
          %PostImage{user_id: user.id, token: token}
          |> Ecto.Changeset.change(meta)
          |> Repo.insert()

        {:error, _} = error ->
          error
      end
    end
  end

  def update_image_alt(%PostImage{} = image, alt) do
    image |> PostImage.alt_changeset(%{alt: alt}) |> Repo.update()
  end

  @doc "Deletes a pending (unattached) image: row and files."
  def delete_pending_image(%PostImage{post_id: nil} = image) do
    {count, _} =
      Repo.delete_all(from(i in PostImage, where: i.id == ^image.id and is_nil(i.post_id)))

    if count == 1, do: PostImageStore.delete(image.token)
    :ok
  end

  @doc "The image behind a proxy token, with its post preloaded; `nil` when unknown."
  def get_image_by_token(token) when is_binary(token) do
    PostImage
    |> Repo.get_by(token: token)
    |> case do
      nil -> nil
      image -> Repo.preload(image, :post)
    end
  end

  def get_image_by_token(_), do: nil

  @doc """
  Whether `viewer` may fetch this image's bytes: pending images belong to
  their uploader alone; attached images follow the post's audience.
  """
  def image_visible_to?(%PostImage{post_id: nil, user_id: uploader_id}, viewer) do
    match?(%User{id: ^uploader_id}, viewer)
  end

  def image_visible_to?(%PostImage{} = image, viewer) do
    post =
      case image.post do
        %Post{} = post -> post
        # Not preloaded (NotLoaded is truthy — don't `||` this).
        _ -> Repo.get(Post, image.post_id)
      end

    visible_to?(post, viewer)
  end

  @doc """
  Removes pending images older than a day (abandoned composer sessions),
  files included. Returns the number of swept images.
  """
  def sweep_pending_images(max_age_hours \\ @pending_max_age_hours) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -max_age_hours * 3600)

    from(i in PostImage, where: is_nil(i.post_id) and i.inserted_at < ^cutoff)
    |> Repo.all()
    |> Enum.count(fn image ->
      # Re-check pending state in the delete itself: the image may have been
      # attached between the read and now.
      {count, _} =
        Repo.delete_all(from(i in PostImage, where: i.id == ^image.id and is_nil(i.post_id)))

      if count == 1, do: PostImageStore.delete(image.token)
      count == 1
    end)
  end

  @doc """
  Person typeahead for the composer's "Hide from…" sheet: validated members
  matching `term` by name or slug, the author excluded (denying yourself is
  a no-op by invariant). Returns `[]` below two characters.
  """
  def search_users(%User{id: author_id}, term, limit \\ 8) when is_binary(term) do
    term = String.trim(term)

    if String.length(term) < 2 do
      []
    else
      pattern = "%" <> escape_like(term) <> "%"

      Repo.all(
        from(u in User,
          where: u.id != ^author_id,
          where: is_nil(u.validated?) or u.validated? == true,
          where:
            ilike(u.first_name, ^pattern) or ilike(u.last_name, ^pattern) or
              ilike(u.active_slug, ^pattern) or
              ilike(fragment("? || ' ' || ?", u.first_name, u.last_name), ^pattern),
          order_by: [u.first_name, u.last_name],
          limit: ^limit
        )
      )
    end
  end

  defp escape_like(term), do: String.replace(term, ~r/([\\%_])/, "\\\\\\1")

  ## Tags

  defp parse_tag_values(nil), do: []

  defp parse_tag_values(values) when is_binary(values),
    do: parse_tag_values(String.split(values, ","))

  defp parse_tag_values(values) when is_list(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(@max_tags)
  end

  # Find-or-create by name/slug (case-insensitive), racing gracefully.
  # Unresolvable values (e.g. names whose slug exceeds the limit) are skipped:
  # a post must not fail because one tag was odd.
  defp tag_ids_for(values) do
    values
    |> Enum.map(&tag_for_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp tag_for_value(value) do
    case lookup_tag(value) do
      %Tag{id: id} -> id
      nil -> insert_tag_for_value(value)
    end
  end

  defp insert_tag_for_value(value) do
    case Repo.insert(Tag.changeset(%Tag{}, %{"value" => value})) do
      {:ok, tag} -> tag.id
      # Lost a race or invalid value — one more lookup, then give up.
      {:error, _} -> with(%Tag{id: id} <- lookup_tag(value), do: id)
    end
  end

  defp lookup_tag(value) do
    down = String.downcase(value)

    Repo.one(
      from(t in Tag,
        where: fragment("lower(?)", t.name) == ^down or t.slug == ^down,
        limit: 1
      )
    )
  end

  ## Broadcasts

  defp broadcast_new_post(%Post{} = post) do
    event = {:new_post, %{post_id: post.id, author_id: post.user_id}}

    follower_ids =
      Repo.all(
        from(c in Connection, where: c.followee_id == ^post.user_id, select: c.follower_id)
      )

    Enum.each([post.user_id | follower_ids], &Vutuv.Activity.broadcast(&1, event))
  end

  ## Param helpers (attrs arrive with atom keys from code, string keys from forms)

  defp fetch(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp parse_ids(ids) when is_list(ids),
    do: ids |> Enum.map(&parse_id/1) |> Enum.reject(&is_nil/1)

  defp parse_id(nil), do: nil
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
