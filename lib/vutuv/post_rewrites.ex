defmodule Vutuv.PostRewrites do
  @moduledoc """
  A member's private search-and-replace rules, per author: regular expressions
  that rewrite the text of one account's posts before they render for **that
  member** — the "Gepostet in GOLEM @golem-Golemde" a Flipboard mirror puts
  under every post, a signature, a wall of hashtags.

  The sibling of `Vutuv.ContentFilters`, and shaped like it: the feed compiles
  the member's whole list once per page (`compile_for/1`) and hands each entry
  through `rewrite_entry/3`, which replaces the text **inside the record** —
  `Post.body`, `RemotePost.content_text`, `Note.content_text` — so everything
  downstream of it (the card, the translation, the tag chips, the content
  filter) reads one text and cannot disagree about which. The stored row is
  never written: a cached post from another network is one copy shared by
  everybody who follows its author, and the rule is one reader's. Never the
  member's own posts, so the edit form never sees a rewritten body.

  **Why text and not HTML.** A post from another network arrives as HTML and is
  reduced to plain text at the inbox (`Vutuv.RemoteHtml.to_text/3`); the card
  renders from that text, the agent formats print it, and the original markup is
  kept nowhere. A member's post is Markdown. So a rule reads exactly the text
  the reader would otherwise see, and the editor can show it as the "before".

  **A rule is a handle.** `account` is the author's handle as the app spells it
  (`@golemde@flipboard.com`, `@handle`), read from `Vutuv.Posts.account_names/1`
  — one string column for all three author kinds instead of the nullable
  foreign-key pair that cost the organization milestone twenty-one silent
  misses. A member who renames loses the rules aimed at their old handle, which
  is rare and visible.

  **A member's regex is untrusted input.** PCRE backtracks, so `(a+)+$` on forty
  characters runs for hours; every match here runs with `match_limit`, which
  makes the engine give up after a bounded number of steps and leave the text as
  it was — measured: the catastrophic pattern returns in half a millisecond
  instead of never. Patterns are capped at 255 characters and compiled once per
  page, never per post.
  """

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Ordering
  alias Vutuv.PostRewrites.PostRewrite
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.UUIDv7

  # Enough rules for any footer-and-signature combination, few enough that a
  # page of posts by one account costs a bounded number of regex passes — and a
  # ceiling on the whole list, so one member's feed never compiles thousands.
  @max_per_account 50
  @max_per_user 200

  # PCRE's internal step budget per match. Generous for any real rule over a
  # 10,000-character post (a footer rule finishes in tens of steps) and the
  # ceiling that turns a catastrophic pattern into a no-op.
  @match_limit 50_000
  @run_opts [:global, {:match_limit, @match_limit}]
  @replace_opts [{:return, :binary} | @run_opts]

  # How many of a member's newest posts are looked at for a sample when the
  # editor was opened without one (the list mixes in reposts, which are
  # somebody else's words).
  @sample_depth 5

  @doc "The maximum number of rules one member may keep for one account."
  def max_per_account, do: @max_per_account

  @doc "The maximum number of rules one member may keep in all."
  def max_per_user, do: @max_per_user

  ## Reading

  @doc "Every rule of the member, grouped by account and in running order. `[]` when logged out."
  def list_for_user(nil), do: []

  def list_for_user(%User{id: user_id}) do
    Repo.all(
      from(r in PostRewrite,
        where: r.user_id == ^user_id,
        order_by: [asc: r.account, asc: r.position, asc: r.id]
      )
    )
  end

  @doc "The member's rules for one account, in running order."
  def list_for_account(%User{id: user_id}, account) do
    case normalize_account(account) do
      nil -> []
      key -> user_id |> account_scope(key) |> Ordering.by_position() |> Repo.all()
    end
  end

  @doc "The accounts the member keeps rules for, as `%{account:, count:}` rows."
  def accounts_for_user(%User{id: user_id}) do
    Repo.all(
      from(r in PostRewrite,
        where: r.user_id == ^user_id,
        group_by: r.account,
        select: %{account: r.account, count: count(r.id)},
        order_by: [asc: r.account]
      )
    )
  end

  @doc "One of the member's rules by id, or nil — scoped to the owner."
  def get_rule(%User{id: user_id}, id) do
    case UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get_by(PostRewrite, id: uuid, user_id: user_id)
    end
  end

  @doc "A changeset for the add form."
  def change_rule(attrs \\ %{}), do: PostRewrite.changeset(%PostRewrite{}, attrs)

  # The owner's rules for one account: the queryable every per-account read
  # and every `Vutuv.Ordering` call is scoped by, so a rule can only ever trade
  # places with one aimed at the same author.
  defp account_scope(user_id, key),
    do: from(r in PostRewrite, where: r.user_id == ^user_id and r.account == ^key)

  ## Writing

  @doc """
  Append a rule to the member's list for `account`. `user_id`, `account` and
  `position` are set here, never cast, so a request can only add to its own
  list. Refuses past the account's cap with `{:error, :too_many_for_account}`
  and past the member's with `{:error, :too_many}`.
  """
  def create_rule(%User{id: user_id}, account, attrs) do
    with key when is_binary(key) <- normalize_account(account) || {:error, :invalid_account},
         :ok <- within_caps(user_id, key) do
      %PostRewrite{
        user_id: user_id,
        account: key,
        position: Ordering.next_position(account_scope(user_id, key), user_id)
      }
      |> PostRewrite.changeset(attrs)
      |> Repo.insert()
    end
  end

  defp within_caps(user_id, key) do
    cond do
      count_of(account_scope(user_id, key)) >= @max_per_account ->
        {:error, :too_many_for_account}

      count_of(from(r in PostRewrite, where: r.user_id == ^user_id)) >= @max_per_user ->
        {:error, :too_many}

      true ->
        :ok
    end
  end

  defp count_of(query), do: Repo.aggregate(query, :count)

  @doc """
  Remove one of the member's rules. Scoped to the owner, and a malformed id is
  a miss rather than a crash.
  """
  def delete_rule(%User{} = user, id) do
    case get_rule(user, id) do
      nil ->
        {:error, :not_found}

      rule ->
        Repo.delete!(rule)
        :ok
    end
  end

  @doc """
  Move one of the member's rules one step up or down within its account's
  order (`Vutuv.Ordering.move/4`, scoped to that account's rows). At the end of
  the list it stays put.
  """
  def move_rule(%User{id: user_id} = user, id, direction) when direction in [:up, :down] do
    case get_rule(user, id) do
      nil ->
        {:error, :not_found}

      rule ->
        Ordering.move(account_scope(user_id, rule.account), user_id, rule.id, direction)
        :ok
    end
  end

  ## Accounts

  @doc """
  The handle of whoever wrote `record`, as the app displays it
  (`@Golemde@flipboard.com`, `@handle`) — or nil for an author nobody can name.
  Read from `Vutuv.Posts.account_names/1`, so it names exactly the account a
  content filter's scope would, for every kind of post and for a bare author.
  """
  def account_handle(record) do
    record |> Posts.account_names() |> Enum.find(&String.starts_with?(&1, "@"))
  end

  @doc "The key a rule is stored under for whoever wrote `record`: `account_handle/1`, normalized."
  def account_key(record), do: record |> account_handle() |> normalize_account()

  @doc """
  The stored spelling of an account typed or pasted by hand: trimmed, one
  leading `@`, downcased — or nil for anything that is not a handle.
  """
  def normalize_account(nil), do: nil

  def normalize_account(account) when is_binary(account) do
    handle = account |> String.trim() |> String.trim_leading("@") |> String.downcase()

    if handle == "" or String.length(handle) > 253 or String.match?(handle, ~r/\s/u),
      do: nil,
      else: "@" <> handle
  end

  ## Compiling and applying

  @doc """
  The member's rules compiled for a page: a map from account key to that
  account's rules in running order, each `%{re:, replacement:, pattern:}` with
  the replacement already in PCRE's syntax. `%{}` for a member with no rules or
  a logged-out visitor, so callers can skip the work.
  """
  def compile_for(user), do: user |> list_for_user() |> compile()

  @doc """
  Compile a list of `%PostRewrite{}` rows into the map above. The account is
  normalized on the way, so rows a test or a preview built by hand key the same
  way `account_key/1` reads a post.
  """
  def compile(rules) do
    rules
    |> Enum.flat_map(fn rule ->
      with key when is_binary(key) <- normalize_account(rule.account),
           {:ok, compiled} <- compile_rule(rule.pattern, rule.replacement) do
        [{key, compiled}]
      else
        _unusable -> []
      end
    end)
    |> Enum.group_by(fn {account, _compiled} -> account end, fn {_account, compiled} ->
      compiled
    end)
  end

  @doc """
  One rule compiled on its own: `{:ok, %{re:, replacement:, pattern:}}` or
  `{:error, reason}` — for the editor's preview of a rule that is still being
  typed, compiled exactly as the saved one will be.
  """
  def compile_rule(pattern, replacement) do
    with {:ok, re} <- PostRewrite.compile_pattern(pattern) do
      {:ok, %{re: re, pattern: pattern, replacement: prepare_replacement(replacement || "")}}
    end
  end

  # PCRE's replacement syntax has `&` for the whole match, which nobody typing
  # "Golem & Co" means; the app's syntax is `\\0` for that, as in `Regex.replace/4`.
  defp prepare_replacement(replacement) do
    replacement
    |> String.replace("&", "\\&")
    |> String.replace("\\0", "&")
  end

  @doc """
  The compiled rules `viewer` keeps for `author` (a `%RemoteAccount{}`, a
  `%User{}` — any record `account_handle/1` can name), or `[]`. One query for
  that account alone, for a page that already knows whose posts it holds; pair
  it with `rewrite_with/2`.
  """
  def author_rules(viewer, author) do
    with %User{} <- viewer,
         key when is_binary(key) <- account_key(author) do
      viewer |> list_for_account(key) |> compile() |> Map.get(key, [])
    else
      _nobody -> []
    end
  end

  @doc "True when the compiled map holds at least one rule."
  def any?(compiled), do: compiled != %{}

  @doc """
  `text` with `rules` (compiled) applied top to bottom, each on the previous
  rule's output. Trimmed at both ends when something changed, so a deleted
  first or last line does not leave its blank behind; an unchanged text comes
  back **as the same binary**, because a cached translation is keyed to it.
  """
  def rewrite_text(text, rules) when is_binary(text) do
    result = Enum.reduce(rules, text, &replace(&2, &1))

    if result == text, do: text, else: String.trim(result)
  end

  defp replace(text, %{re: re, replacement: replacement}) do
    :re.replace(text, re, replacement, @replace_opts)
  rescue
    # A subject the unicode-mode engine refuses (invalid UTF-8 would have been
    # rejected at the write, but the answer to a doubt here is "unchanged").
    ArgumentError -> text
  end

  @doc """
  `record` with its text rewritten by the rules aimed at its author, or the
  record as it was. Never the viewer's own post, and never a record whose text
  is nil (a wordless photo post stays wordless).
  """
  def rewrite(record, compiled, _viewer_id) when compiled == %{}, do: record

  def rewrite(%Post{user_id: viewer_id} = post, _compiled, viewer_id)
      when is_binary(viewer_id),
      do: post

  def rewrite(record, compiled, _viewer_id) do
    case account_key(record) do
      nil -> record
      key -> rewrite_with(record, Map.get(compiled, key, []))
    end
  end

  @doc "`record` with one account's `rules` applied to its text, or as it was."
  def rewrite_with(record, []), do: record

  def rewrite_with(record, rules) do
    case Posts.text(record) do
      text when is_binary(text) -> Posts.put_text(record, rewrite_text(text, rules))
      _nil -> record
    end
  end

  @doc "Each of `records` through `rewrite/3`."
  def rewrite_all(records, compiled, _viewer_id) when compiled == %{}, do: records

  def rewrite_all(records, compiled, viewer_id),
    do: Enum.map(records, &rewrite(&1, compiled, viewer_id))

  @doc """
  A feed entry with **every** record it draws rewritten — the post it is keyed
  on, the ancestors folded into its row, the cached posts an answer answers and
  the replies from other networks woven into its thread
  (`Vutuv.Posts.map_entry_records/2` owns that shape), because a rule that
  skipped the folded parent would show the footer exactly where the reader was
  not looking for it.
  """
  def rewrite_entry(entry, compiled, _viewer_id) when compiled == %{}, do: entry

  def rewrite_entry(entry, compiled, viewer_id),
    do: Posts.map_entry_records(entry, &rewrite(&1, compiled, viewer_id))

  ## Preview

  @doc """
  `text` cut into `{:plain, part}` and `{:hit, part}` segments around what
  `rule` (compiled) matches — the editor's "before" pane, which marks the
  spans a rule catches. Empty matches (`^`, `\\b`) mark nothing. On a match
  budget overrun the whole text is one plain segment, the same "unchanged" the
  rewrite answers.
  """
  def segments(text, %{re: re}) when is_binary(text) do
    case :re.run(text, re, [{:capture, :first, :index} | @run_opts]) do
      {:match, spans} -> cut(text, 0, Enum.reject(spans, fn [{_start, len}] -> len == 0 end), [])
      _none -> [{:plain, text}]
    end
  end

  defp cut(text, from, [], acc) do
    rest = binary_part(text, from, byte_size(text) - from)
    Enum.reverse(if rest == "", do: acc, else: [{:plain, rest} | acc])
  end

  defp cut(text, from, [[{start, len}] | spans], acc) do
    acc = if start > from, do: [{:plain, binary_part(text, from, start - from)} | acc], else: acc
    cut(text, start + len, spans, [{:hit, binary_part(text, start, len)} | acc])
  end

  ## The sample post

  @doc """
  The post the editor previews rules for `account` on: the one the ⋯ menu
  named (`{:post | :remote_post | :note, id}`) if `viewer` may read it and this
  account wrote it, else the account's newest post the viewer may read, else
  nil.
  """
  def sample(named, account, viewer) do
    case named && named_sample(named, viewer) do
      nil ->
        latest_sample(account, viewer)

      record ->
        if account_key(record) == account, do: record, else: latest_sample(account, viewer)
    end
  end

  defp named_sample({:remote_post, id}, viewer) do
    post = Fediverse.get_remote_post(id)
    if post && Fediverse.remote_post_readable?(post, viewer), do: post
  end

  defp named_sample({:post, id}, viewer) do
    post = Posts.get_post(id)
    if post && Posts.visible_to?(post, viewer), do: post
  end

  defp named_sample({:note, id}, viewer) do
    note = Fediverse.get_note(id)
    if note && Fediverse.note_readable?(note, viewer), do: note
  end

  # An address with a host names an account elsewhere, a bare handle a member
  # here — the same split the account key encodes.
  defp latest_sample("@" <> handle = account, viewer) do
    if String.contains?(handle, "@"),
      do: latest_remote_sample(account, viewer),
      else: latest_member_sample(handle, viewer)
  end

  defp latest_sample(_account, _viewer), do: nil

  defp latest_remote_sample(account, viewer) do
    with %{} = remote_account <- Fediverse.remote_account_by_address(account),
         {[post | _rest], _more?} <- Fediverse.account_posts(remote_account, viewer) do
      %{post | remote_account: remote_account}
    else
      _none -> nil
    end
  end

  defp latest_member_sample(handle, viewer) do
    with %User{id: author_id} = author <- Accounts.get_user_by_username(handle) do
      author
      |> Posts.profile_posts(viewer, limit: @sample_depth)
      |> Enum.find_value(fn
        %{post: %Post{user_id: ^author_id} = post} -> post
        _repost -> nil
      end)
    end
  end
end
