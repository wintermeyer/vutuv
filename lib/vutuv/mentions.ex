defmodule Vutuv.Mentions do
  @moduledoc """
  The `@handle` mention grammar and everything the site does with it.

  A mention is plain text `@handle` inside a Markdown body — nothing structured
  is stored, it becomes a profile link only at render time
  (`VutuvWeb.Markdown`). Three concerns therefore have to agree on *what counts
  as a mention*, so they share one definition here:

    * **Rendering** — `VutuvWeb.Markdown` links each local `@handle` and calls
      `entity_regex/0` so the grammar can never drift from this module.
    * **Validation** — a saved body may only mention handles that already exist
      (`validate_mentions_exist/2`). Without this a bad actor could seed
      `@wanted` into a post to *reserve* it: the availability rule below then
      treats `@wanted` as "used in content" and blocks everyone from claiming
      it. Requiring the mention target to exist closes that reservation attack.
    * **Propagation** — when a member renames, every stored `@old` is rewritten
      to `@new` across all mention surfaces (`rewrite_everywhere/3`), and the
      new handle is only claimable when it is used in no content
      (`used_in_content?/1`), so a rename cannot hijack someone else's existing
      `@new` links.

  Only the **local** `@handle` form is a vutuv handle. A fediverse `@user@host`
  handle and a `#hashtag` are never touched by any function here, and a handle
  inside a code span/block is sample text, not a mention (matching what the
  renderer links).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Vutuv.Accounts.User
  alias Vutuv.Ads.Ad
  alias Vutuv.Chat.Message
  alias Vutuv.Handles
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts.Post
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.SearchText

  # The canonical `@`/`#` entity grammar. It lives here (not in the renderer) so
  # rendering, validation and rewriting share ONE definition; `VutuvWeb.Markdown`
  # reads it through `entity_regex/0`. The leading `@`/`#` must not sit
  # mid-token — no email `a@b`, no `@@`, no `/path#frag` — hence the negative
  # lookbehinds. The fediverse form is tried first, so `@a@b.social` links to
  # the remote account instead of the local member `@a`. Captures: 1 = fediverse
  # user, 2 = fediverse host, 3 = local handle, 4 = hashtag (exactly one kind is
  # set per hit).
  @entity ~r{(?<![\w@/])@([A-Za-z0-9_]+)@([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+)|(?<![\w@/])@([A-Za-z0-9_]+)|(?<![\w#/&])#([A-Za-z0-9_]+)}

  # Code spans/blocks are skipped everywhere: a handle inside them is sample
  # text, never a link (the same call the renderer makes for `<code>`/`<pre>`).
  # Fenced (``` / ~~~) is tried before inline so a fence is one unit.
  # `Regex.split(_, include_captures: true)` on a pattern with no capture groups
  # returns `[text, code, text, code, …, text]`, which rejoins to the exact
  # original — so `rewrite/3` can never corrupt a body.
  @code ~r/```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`/

  # Every Markdown surface whose stored `@handle` becomes a link — the single
  # list the existence validation, the content scan and the rename rewrite all
  # read, kept in step with the `VutuvWeb.Markdown` render call sites.
  @surfaces [
    {Post, :body},
    {Message, :body},
    {User, :headline},
    {WorkExperience, :description},
    {Education, :description},
    {JobPosting, :description},
    {Ad, :content}
  ]

  @doc "The canonical entity regex, so the renderer shares this module's grammar."
  def entity_regex, do: @entity

  @doc "The `{schema, field}` mention surfaces scanned and rewritten by this module."
  def surfaces, do: @surfaces

  ## Detection --------------------------------------------------------------

  @doc """
  The unique, lowercased local `@handles` mentioned in `text`.

  Fediverse `@user@host` handles and `#hashtags` are excluded; handles inside
  code spans/blocks are ignored.
  """
  def local_handles(text) when is_binary(text) do
    if String.contains?(text, "@") do
      text
      |> text_chunks()
      |> Enum.flat_map(&scan_handles/1)
      |> Enum.uniq()
    else
      []
    end
  end

  def local_handles(_), do: []

  @doc "Whether `text` mentions `handle` (case-insensitive; a leading `@` is optional)."
  def mentions?(text, handle) when is_binary(text) do
    normalize(handle) in local_handles(text)
  end

  def mentions?(_, _), do: false

  ## Rewrite ----------------------------------------------------------------

  @doc """
  Rewrites every local `@old` mention in `text` to `@new`, returning
  `{rewritten, count}`.

  Emails, hashtags, fediverse handles and code spans are left untouched, and a
  body with nothing to change round-trips byte-for-byte.
  """
  def rewrite(text, old, new) when is_binary(text) do
    old_n = normalize(old)
    new_n = normalize(new)

    if old_n == "" or old_n == new_n or not String.contains?(text, "@") do
      {text, 0}
    else
      {chunks, count} =
        text
        |> chunks()
        |> Enum.map_reduce(0, fn
          {:code, chunk}, acc -> {chunk, acc}
          {:text, chunk}, acc -> rewrite_chunk(chunk, old_n, "@" <> new_n, acc)
        end)

      {IO.iodata_to_binary(chunks), count}
    end
  end

  def rewrite(text, _old, _new), do: {text, 0}

  ## Existence validation ---------------------------------------------------

  @doc """
  The local handles mentioned in `text` that do **not** exist in the handle
  registry (members or organizations), lowercased.
  """
  def unknown_handles(text) do
    case local_handles(text) do
      [] ->
        []

      handles ->
        existing = existing_handles(handles)
        Enum.reject(handles, &MapSet.member?(existing, &1))
    end
  end

  @skip_key :__vutuv_skip_mention_existence__

  @doc """
  Runs `fun` with the mention-existence check relaxed for this process.

  The bulk **LinkedIn import** carries arbitrary external prose (a work-history
  description may legitimately read "Managed the @Acme account"), so forcing
  every imported `@token` to resolve to a member would silently drop those rows.
  The import wraps its one transaction in this so those bodies store verbatim; a
  rename still rewrites them, and nothing here is a reservation vector because
  only posts are scanned for availability.
  """
  def without_existence_check(fun) when is_function(fun, 0) do
    previous = Process.put(@skip_key, true)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@skip_key), else: Process.put(@skip_key, previous)
    end
  end

  @doc """
  Rejects a changeset whose Markdown `field` mentions a handle that does not
  exist, so nobody can seed `@wanted` into content to reserve it. Runs only when
  `field` actually changed; the rename rewrite bypasses changesets entirely (so
  a body's other, now-dead mentions never block it) and the import relaxes it
  via `without_existence_check/1`.
  """
  def validate_mentions_exist(changeset, field \\ :body)

  def validate_mentions_exist(changeset, field) do
    if Process.get(@skip_key) do
      changeset
    else
      do_validate_mentions_exist(changeset, field)
    end
  end

  defp do_validate_mentions_exist(changeset, field) do
    case Changeset.get_change(changeset, field) do
      text when is_binary(text) ->
        case unknown_handles(text) do
          [] ->
            changeset

          unknown ->
            # A self-contained, actionable sentence (not a fragment prefixed by
            # the field name) that names the offending handle(s) and is plural
            # aware via the `count:` opt — so the composer's live error and the
            # classic pages' `error_tag` both read cleanly. The German copy lives
            # in `priv/gettext/*/errors.po`.
            Changeset.add_error(
              changeset,
              field,
              "The handle %{handles} does not exist. Remove the mention or check the spelling.",
              count: length(unknown),
              handles: Enum.map_join(unknown, ", ", &("@" <> &1))
            )
        end

      _ ->
        changeset
    end
  end

  @doc """
  Rejects a changeset whose handle `field` is already mentioned in a public
  post, so a deliberate rename/claim cannot silently inherit someone else's
  existing `@handle` links. Runs only on an otherwise-valid changeset with a
  changed field, so grammar errors surface first and an unchanged handle is
  never scanned.
  """
  def validate_handle_available(changeset, field \\ :username) do
    with true <- changeset.valid?,
         handle when is_binary(handle) <- Changeset.get_change(changeset, field),
         true <- mentioned_in_posts?(handle) do
      Changeset.add_error(changeset, field, "is already used in a post, so it can't be claimed")
    else
      _ -> changeset
    end
  end

  ## Availability + propagation (DB) ----------------------------------------

  @doc """
  Whether `handle` is already used as a mention in any **public post**.

  The anti-hijack half of handle availability: a handle already linked from a
  post must not be claimable, or the claimant would silently capture those
  existing `@handle` links. Scoped to posts (public content) on purpose — a
  private DM must not make a handle globally unclaimable, and rewriting on
  rename keeps posts free of a departed handle so a freed name stays reusable.
  """
  def mentioned_in_posts?(handle) do
    normalized = normalize(handle)

    normalized != "" and surface_uses_handle?(Post, :body, normalized)
  end

  @doc """
  How many public posts mention `handle` (the precise count, not a substring
  match). Backs the "N posts will be updated" preview on the rename form and the
  success flash.
  """
  def count_post_mentions(handle) do
    normalized = normalize(handle)

    if normalized == "" do
      0
    else
      pattern = "%@" <> SearchText.escape_like(normalized) <> "%"

      from(p in Post, where: ilike(p.body, ^pattern), select: p.body)
      |> Repo.all()
      |> Enum.count(&mentions?(&1, normalized))
    end
  end

  @doc """
  Rewrites every stored `@old` mention to `@new` across all surfaces, using
  `repo` so it is atomic with the caller's rename transaction.

  Returns `%{posts: [%Post{}], counts: %{surface => changed_row_count}}`. Only
  the changed `Post` structs are returned (their authors are notified); the
  write goes through `Ecto.Changeset.change/2`, bypassing each schema's
  changeset, so a body's other now-dead mentions never block the rewrite.
  """
  def rewrite_everywhere(repo \\ Repo, old, new) do
    old_n = normalize(old)
    new_n = normalize(new)

    Enum.reduce(
      @surfaces,
      %{posts: [], counts: %{}},
      &accumulate_surface(repo, &1, old_n, new_n, &2)
    )
  end

  defp accumulate_surface(repo, {schema, field}, old_n, new_n, acc) do
    changed = rewrite_surface(repo, schema, field, old_n, new_n)
    posts = if schema == Post, do: changed, else: acc.posts

    %{posts: posts, counts: Map.put(acc.counts, surface_key(schema), length(changed))}
  end

  ## Internals --------------------------------------------------------------

  defp scan_handles(chunk) do
    @entity
    |> Regex.scan(chunk, capture: :all_but_first)
    |> Enum.flat_map(&handle_of/1)
  end

  # `Regex.scan` truncates trailing unmatched groups, so a hit's length says
  # which kind it is: fediverse `["user", "host"]`, local `["", "", "handle"]`,
  # hashtag `["", "", "", "hashtag"]`.
  defp handle_of([user, host | _]) when user != "" and host != "", do: []
  defp handle_of([_, _, handle | _]) when handle != "", do: [String.downcase(handle)]
  defp handle_of(_), do: []

  defp rewrite_chunk(chunk, old_n, replacement, acc) do
    hits =
      @entity
      |> Regex.scan(chunk, capture: :all_but_first)
      |> Enum.count(&local_match?(&1, old_n))

    if hits == 0 do
      {chunk, acc}
    else
      {replace_old_mentions(chunk, old_n, replacement), acc + hits}
    end
  end

  defp replace_old_mentions(chunk, old_n, replacement) do
    Regex.replace(@entity, chunk, fn
      whole, "", "", handle, "" ->
        if String.downcase(handle) == old_n, do: replacement, else: whole

      whole, _user, _host, _handle, _hashtag ->
        whole
    end)
  end

  defp local_match?([_, _, handle | _], old_n) when handle != "",
    do: String.downcase(handle) == old_n

  defp local_match?(_, _), do: false

  # Splits `text` into `{:text, _}` / `{:code, _}` chunks that rejoin exactly.
  defp chunks(text) do
    @code
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      if rem(index, 2) == 0, do: {:text, chunk}, else: {:code, chunk}
    end)
  end

  defp text_chunks(text) do
    for {:text, chunk} <- chunks(text), do: chunk
  end

  defp surface_uses_handle?(schema, field, handle) do
    pattern = "%@" <> SearchText.escape_like(handle) <> "%"

    from(row in schema, where: ilike(field(row, ^field), ^pattern), select: field(row, ^field))
    |> Repo.all()
    |> Enum.any?(&mentions?(&1, handle))
  end

  defp rewrite_surface(repo, schema, field, old_n, new_n) do
    pattern = "%@" <> SearchText.escape_like(old_n) <> "%"

    from(row in schema, where: ilike(field(row, ^field), ^pattern))
    |> repo.all()
    |> Enum.reduce([], fn row, acc ->
      old_value = Map.fetch!(row, field)
      {new_value, count} = rewrite(old_value, old_n, new_n)

      if count > 0 and new_value != old_value do
        row |> Changeset.change(%{field => new_value}) |> repo.update!()
        [row | acc]
      else
        acc
      end
    end)
  end

  # "Exists" = a member or organization actually holds the handle (the shared
  # `/:handle` namespace, issue #941), queried against the owner tables directly
  # so it matches what the renderer resolves and never depends on the registry
  # backfill. Usernames are stored lowercase, so `handles` (already lowercased)
  # compares directly.
  defp existing_handles(handles) do
    members = Repo.all(from(u in User, where: u.username in ^handles, select: u.username))
    orgs = Repo.all(from(o in Organization, where: o.username in ^handles, select: o.username))

    MapSet.new(members ++ orgs)
  end

  defp surface_key(Post), do: :posts
  defp surface_key(Message), do: :messages
  defp surface_key(User), do: :headlines
  defp surface_key(WorkExperience), do: :work_experiences
  defp surface_key(Education), do: :educations
  defp surface_key(JobPosting), do: :job_postings
  defp surface_key(Ad), do: :ads

  defp normalize(value) when is_binary(value), do: Handles.normalize(value)

  defp normalize(_), do: ""
end
