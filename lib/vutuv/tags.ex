defmodule Vutuv.Tags do
  @moduledoc """
  The Tags context: adding tags to users (one name or a batch of them, the path
  registration and the tags page share) and user tag endorsements.

  Tags may contain spaces ("Ruby on Rails"). When a member types a batch, an
  unquoted comma or space still separates tags, so `"Elixir, Phoenix Go"` is
  three tags; a multi-word tag is grouped with quotes, so `"Elixir "Ruby on
  Rails""` is two. `parse_tag_names/1` is the single tokenizer for that rule.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement

  # The endorsers list: which columns it can be sorted by, and a denser page
  # size than the site-wide default so a popular tag's list actually paginates.
  @endorser_sorts ~w(name username date)
  @endorsers_per_page 25

  # The most tags one profile may carry. A handful of members overdid it, so a
  # profile is capped here. The cap bites only when tags *change*: a profile
  # already over it (from before the cap) keeps every tag but can add none, and
  # the sign-up form validates the same ceiling up front.
  @max_user_tags 15

  # Matches one token: either a `"…"` quoted phrase (capturing its inside, which
  # may hold spaces) or a run of non-space, non-comma characters. Tried
  # left-to-right at each position, so a well-formed `"…"` is always taken whole
  # before the bare alternative can nibble at it.
  @token_regex ~r/"([^"]*)"|[^\s,]+/
  # Curly/German/guillemet quotes a phone keyboard autocorrects to, folded to a
  # straight `"` so grouping works no matter which quote the member typed.
  @fancy_quotes ~r/[\x{201C}\x{201D}\x{201E}\x{201F}\x{00AB}\x{00BB}]/u

  @doc """
  Tokenizes a tag string into clean names. An unquoted comma or run of
  whitespace separates tags, and a `"…"` quoted phrase is kept as one
  multi-word tag: `~s(PHP, "Ruby on Rails" Go)` → `["PHP", "Ruby on Rails",
  "Go"]`, while the same words unquoted (`"Ruby on Rails"`) stay one tag per
  word. Curly and German quotes are accepted too; an unbalanced quote degrades
  to word splitting rather than swallowing the rest of the line. A leading `#`
  (the hashtag form) is stripped from each token and interior whitespace is
  collapsed (`Tag.normalize_value/1`), so `"#Elixir #Phoenix"` →
  `["Elixir", "Phoenix"]` and a bare `"#"` drops out. Safe to call with `nil`
  (returns `[]`).
  """
  def parse_tag_names(value) when is_binary(value) do
    value
    |> String.replace(@fancy_quotes, "\"")
    |> then(&Regex.scan(@token_regex, &1))
    |> Enum.map(&token_from_match/1)
    |> Enum.map(&Tag.normalize_value/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_tag_names(_), do: []

  # A quoted match arrives as `["\"phrase\"", "phrase"]` (full then the inner
  # capture); a bare match as `["token", ""]`. Use the capture only for a real
  # `"…"` pair (starts and ends with a quote), and strip any stray quote from a
  # bare token so an unbalanced `"` can never end up in a stored name.
  defp token_from_match([full | rest]) do
    token = if quoted?(full), do: List.first(rest) || "", else: full
    String.replace(token, "\"", "")
  end

  defp quoted?(full),
    do: String.starts_with?(full, "\"") and String.ends_with?(full, "\"") and byte_size(full) >= 2

  @doc """
  The display names a submit of `value` on the add-tag form will actually
  attach, in typed order — the live preview of issue #848. Each parsed name is
  resolved the way `Tag.create_or_link_tag/2` links: an existing tag matched
  case-insensitively by name or slug keeps its stored display name (typing
  `"AhmetSun"` when the tag `ahmetsun` exists yields the chip `ahmetsun`),
  while an unmatched name becomes a fresh tag displaying exactly as typed.
  Case-insensitive duplicates collapse to the first spelling, mirroring the
  single row the profile would end up with (the form's save path dedupes the
  same way, so preview and outcome always agree).
  """
  def preview_tag_names(value) do
    case value |> parse_tag_names() |> Enum.uniq_by(&String.downcase/1) do
      [] ->
        []

      names ->
        downcased = Enum.map(names, &String.downcase/1)

        display_by_key =
          from(t in Tag,
            where: fragment("lower(?)", t.name) in ^downcased or t.slug in ^downcased,
            select: {fragment("lower(?)", t.name), t.slug, t.name}
          )
          |> Repo.all()
          |> Enum.flat_map(fn {lower_name, slug, name} -> [{lower_name, name}, {slug, name}] end)
          |> Map.new()

        Enum.map(names, &Map.get(display_by_key, String.downcase(&1), &1))
    end
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
    from(t in Tag,
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
    Repo.aggregate(from(t in Tag, where: t.honor?), :count)
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

  @doc """
  Given candidate tag slugs (the `#hashtags` in a Markdown body), returns the
  `MapSet` of those naming a real tag with **at least one visible member** — a
  confirmed, non-hidden user carries the tag, so its `/tags/:slug` page actually
  shows something. Powers the hashtag links `VutuvWeb.Markdown` writes; an
  unknown or empty tag is absent from the set, so it stays plain text. The
  visible-member gate is the same one the tag page lists by
  (`Tag.recommended_users/1`). One query; an empty input skips the DB so the
  renderer's no-hashtag path stays query-free.
  """
  def linkable_slugs(slugs) when is_list(slugs) do
    import Vutuv.Moderation.Query, only: [account_hidden: 1, account_confirmed_row: 1]

    case slugs |> Enum.map(&String.downcase/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      normalized ->
        from(t in Tag,
          join: ut in assoc(t, :user_tags),
          join: u in assoc(ut, :user),
          where: t.slug in ^normalized,
          where: account_confirmed_row(u) and not account_hidden(u.id),
          distinct: true,
          select: t.slug
        )
        |> Repo.all()
        |> MapSet.new()
    end
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
end
