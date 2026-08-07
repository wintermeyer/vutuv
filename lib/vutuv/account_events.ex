defmodule Vutuv.AccountEvents do
  @moduledoc """
  The account-activity log (issue #1087): an append-only record of what changed
  on an account, when, from where and how it was confirmed — so a member can
  check for themselves, and support can answer "I didn't do anything!" with
  "your username changed on 3 July at 14:32:07, confirmed by a passkey from a
  Chrome on macOS device".

  ## What a row holds

  Who (`user_id`), what (`kind`), when (`inserted_at`, **microsecond**
  resolution so two changes in one second still have an order), the confirming
  factor, a **coarse** device summary and a small `details` map.
  `actor_user_id` is set only when somebody else did it — an admin acting for
  support — which is what makes "that wasn't me" answerable at a glance.

  **No IP address.** It was in the first cut and is deliberately gone: for the
  member the question is "was that me?", which the device summary, the time and
  the confirming factor answer, while a year of IPs per account is a movement
  profile nobody asked us to keep. (`user_sessions` still stores one per
  signed-in device — that is the devices list and the new-device security email,
  a different feature with its own lifetime.)

  ## What a row must never hold

  Not the value of anything secret or guessable-and-private. No PIN, token,
  passkey material, TOTP secret or one-time list code — those never even reach
  this module. No muted word, no message, no postal address, no IP address.
  Email addresses are stored **masked** (`mask_email/1`: `an***@example.com`),
  enough for the owner to recognize which of their addresses it was, not enough
  for a leaked backup or an admin screen to harvest one.

  That rule is enforced structurally rather than by discipline: `@kinds` is the
  **whole** vocabulary, each kind declares exactly which `details` keys it may
  carry, and `Vutuv.AccountEvents.AccountEvent.changeset/2` rejects anything
  else. Adding a fact to the log means adding it here first, where the review
  question "is this safe to keep for a year?" is unavoidable.
  `test/vutuv/account_events_test.exs` fails the build if a declared key ever
  reads like a credential.

  ## Writing

  `record/3` is the one write path and is **best-effort**: a log write must
  never break the action it records, so a failure is logged and swallowed. Call
  it from the chokepoint that already exists (`Vutuv.Accounts.login/3`,
  `Vutuv.Sessions.revoke/1`, the settings controllers), not from every call
  site.

  ## Reading

  Two readers, one query builder: the member's own page
  (`VutuvWeb.AccountActivityLive`, `/settings/activity`) and the admin's
  cross-member page (`VutuvWeb.Admin.ActivityLive`, `/admin/activity`), which
  logs its own access as an `"activity_log_viewed"` event on the **admin's**
  account.

  ## Retention

  Rows older than `retention_days/0` (365 by default,
  `ACCOUNT_EVENT_RETENTION_DAYS`) are deleted by `Vutuv.AccountEvents.Sweeper`.
  The log is still personal data without the IP: it rides along in the GDPR
  export (`Vutuv.Export`) and cascades away with the account.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.AccountEvents.AccountEvent
  alias Vutuv.Accounts.User
  alias Vutuv.Pages
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.Sessions

  @events_per_page 50

  # ── The vocabulary ──
  #
  # kind => the detail keys that kind may carry. Everything else is rejected by
  # the changeset. Keep the keys boring and non-identifying: a field NAME, a
  # count, a boolean, a public handle, a masked address.
  @kinds %{
    # Sign-in and sessions
    "signed_in" => [],
    "signed_out" => [],
    "session_revoked" => ["target_device"],
    "other_sessions_revoked" => ["count"],

    # The factors themselves
    "passkey_added" => ["nickname"],
    "passkey_removed" => ["nickname"],
    "totp_enabled" => [],
    "totp_disabled" => [],
    "login_codes_generated" => ["count"],
    "login_codes_deleted" => [],

    # Identity
    "username_changed" => ["from", "to"],
    "email_added" => ["email"],
    "email_removed" => ["email"],
    "email_updated" => ["email", "public"],
    "profile_updated" => ["fields"],

    # Privacy and reach
    "privacy_changed" => ["fields"],
    "notifications_changed" => ["fields"],
    "fediverse_changed" => ["enabled"],
    "member_blocked" => ["handle"],
    "member_unblocked" => ["handle"],
    "filter_added" => ["filter_kind"],
    "filter_removed" => ["filter_kind"],
    "auto_post_deletion_changed" => ["fields"],

    # Posts the member's own automatic-deletion rule took (issue #1255), one
    # line per sweeper pass. The count is the whole detail: **which** posts
    # they were is precisely what is gone, and naming them here would rebuild
    # a list of deleted posts inside a log that outlives them by a year.
    "posts_auto_deleted" => ["count"],

    # Employment references (Arbeitszeugnisse). Deliberately **no title and no
    # grade**, only field names: a Zeugnis names a former employer and the
    # review states a mark, this log outlives the entry by up to a year, and a
    # member who deletes a Zeugnis must not leave "Zeugnis Muster GmbH, Note 4
    # bis 5" behind in a page that support also reads. The kinds alone answer
    # what this log is for — "who touched my references, and when".
    "job_reference_added" => [],
    "job_reference_updated" => ["fields"],
    "job_reference_removed" => [],
    "job_reference_reviewed" => ["model"],

    # Data in and out
    "data_exported" => [],
    "import_applied" => ["source"],

    # Apps and API
    "api_token_created" => ["name"],
    "api_token_revoked" => ["name"],
    "app_disconnected" => ["app"],

    # Done to the account by somebody else (actor_user_id is set)
    "account_frozen" => [],
    "account_unfrozen" => [],
    "account_restored" => [],
    "identity_verified" => [],
    "preferences_overridden" => ["fields"],
    "activity_log_viewed" => ["member"]
  }

  @factors ~w(passkey authenticator list_code pin session admin)

  @sort_columns ~w(time kind)
  @admin_sort_columns ~w(time kind member)

  @doc "Every declared event kind. The changeset's whitelist."
  def kinds, do: Map.keys(@kinds)

  @doc "Whether `kind` is a declared event kind."
  def kind?(kind), do: Map.has_key?(@kinds, kind)

  @doc "The `details` keys `kind` may carry, as strings. The per-kind whitelist."
  def detail_keys(kind), do: Map.get(@kinds, kind, [])

  @doc "The whole registry, `kind => allowed detail keys`. Public so a test can audit it."
  def registry, do: @kinds

  @doc "The confirming factors a row may name."
  def factors, do: @factors

  @doc "How many events one page of either activity page shows."
  def events_per_page, do: @events_per_page

  @doc """
  How long an event is kept. Per-installation (`ACCOUNT_EVENT_RETENTION_DAYS`,
  read in `config/runtime.exs`), one year by default: long enough to cover the
  "this happened months ago and I only noticed now" support case, short enough
  that the log is not a permanent movement profile.
  """
  def retention_days, do: Application.get_env(:vutuv, :account_event_retention_days, 365)

  # ── Writing ──

  @doc """
  Records one event for `user`. The single write path.

  `opts`:

    * `:conn` — a `Plug.Conn`, to take the coarse device summary from (never
      the raw User-Agent, and never the IP — see the moduledoc).
    * `:device` — the same, when there is no conn (a LiveView socket, a
      background job).
    * `:factor` — how the member proved it was them, one of `factors/0`.
    * `:actor` — the `%User{}` who did it, when that is **not** the account's
      owner (an admin). Left out for the member's own actions.
    * `:details` — the per-kind extras, whitelisted by `@kinds`.

  Best-effort by design: it returns `:ok` whatever happens, because a log write
  must never break the action it is recording. A rejected changeset (an
  undeclared kind or detail key) is a programming error and is logged as one.
  """
  def record(user, kind, opts \\ [])

  def record(%User{id: user_id}, kind, opts), do: record(user_id, kind, opts)

  def record(user_id, kind, opts) when is_binary(user_id) do
    attrs = %{
      kind: kind,
      factor: opts[:factor],
      device: device(opts),
      details: opts[:details] || %{}
    }

    %AccountEvent{user_id: user_id, actor_user_id: actor_id(opts[:actor])}
    |> AccountEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error("account event #{kind} rejected: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    error ->
      Logger.error("account event #{kind} failed: #{Exception.message(error)}")
      :ok
  end

  def record(_user, _kind, _opts), do: :ok

  # The one request fact the log keeps. Deliberately the coarse summary
  # ("Chrome on macOS") the signed-in-devices list already shows, not the raw
  # User-Agent: the log should say which of your devices it was, not carry a
  # fingerprint for a year.
  defp device(opts) do
    case opts[:conn] do
      %Plug.Conn{} = conn -> conn |> Plug.Conn.get_req_header("user-agent") |> device_summary()
      _ -> opts[:device]
    end
  end

  defp device_summary([ua | _]), do: Sessions.device_summary(ua)
  defp device_summary(_none), do: nil

  defp actor_id(%User{id: id}), do: id
  defp actor_id(_other), do: nil

  @doc """
  A recognizable but non-harvestable rendering of an email address:
  `anna@example.com` becomes `an***@example.com`, `jo@example.com` becomes
  `j***@example.com`.

  The owner knows instantly which of their addresses a row is about; a leaked
  backup, an admin screen or a support transcript does not gain a working
  address. This is the ONLY way an address may enter the log.
  """
  def mask_email(value) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        keep = if String.length(local) > 3, do: 2, else: 1
        String.slice(local, 0, keep) <> "***@" <> domain

      _not_an_address ->
        "***"
    end
  end

  def mask_email(_value), do: nil

  # ── Reading ──

  @doc """
  Normalizes the member page's query params into the filter map both the count
  and the page query take: free-text `q`, a `kind`, and the sort column plus
  direction.
  """
  def filters(params) when is_map(params) do
    sort = validated_sort(params["sort"], @sort_columns)

    %{
      q: Pages.blank_to_nil(params["q"]),
      kind: validated_kind(params["kind"]),
      sort: sort,
      dir: validated_dir(params["dir"]) || default_dir(sort)
    }
  end

  @doc """
  The admin page's filters: the member page's three plus `member` (a free-text
  match on name, @handle or email address) and the wider sort vocabulary.
  """
  def admin_filters(params) when is_map(params) do
    sort = validated_sort(params["sort"], @admin_sort_columns)

    %{
      q: Pages.blank_to_nil(params["q"]),
      kind: validated_kind(params["kind"]),
      member: Pages.blank_to_nil(params["member"]),
      sort: sort,
      dir: validated_dir(params["dir"]) || default_dir(sort)
    }
  end

  @doc """
  The direction a column sorts in when it is picked for the first time: the
  time newest-first (what a log is read for), the text columns A-Z.
  """
  def default_dir("time"), do: "desc"
  def default_dir(_text_column), do: "asc"

  @doc "How many of `user`'s events match `filters` (for the pager)."
  def count(%User{id: user_id}, filters \\ %{}) do
    user_id |> base(filters) |> Repo.aggregate(:count)
  end

  @doc """
  One page of `user`'s own events: filtered, searched, sorted, paginated.
  `opts` may carry `:total` (skip the recount) and `:per_page`.
  """
  def page(%User{id: user_id}, filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @events_per_page)
    base = base(user_id, filters)
    total = Keyword.get(opts, :total) || Repo.aggregate(base, :count)

    base
    |> preload_actor()
    |> order(filters)
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  @doc "How many events across **all** members match `filters` (the admin pager)."
  def admin_count(filters \\ %{}) do
    nil |> base(filters) |> Repo.aggregate(:count)
  end

  @doc """
  One page of the whole installation's log, for support. Preloads each event's
  member and, where set, the admin who acted, so the table can name both.
  """
  def admin_page(filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @events_per_page)
    base = base(nil, filters)
    total = Keyword.get(opts, :total) || Repo.aggregate(base, :count)

    base
    |> preload_actor()
    |> preload([:user])
    |> order(filters)
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  @doc """
  The kinds that actually occur in `user`'s log, so the kind filter offers only
  what is there instead of the whole vocabulary.
  """
  def kinds_present(%User{id: user_id}) do
    Repo.all(
      from(e in AccountEvent, where: e.user_id == ^user_id, distinct: true, select: e.kind)
    )
  end

  @doc "The kinds present across the whole installation (the admin kind filter)."
  def kinds_present do
    Repo.all(from(e in AccountEvent, distinct: true, select: e.kind))
  end

  @doc """
  The member's most recent events, newest first — the short "recently on your
  account" list the security page shows above the device list.
  """
  def recent(%User{id: user_id}, limit \\ 5) do
    Repo.all(
      from(e in AccountEvent,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit,
        preload: [:actor_user]
      )
    )
  end

  @doc """
  Deletes every event older than `retention_days/0` and returns how many went.
  Called by `Vutuv.AccountEvents.Sweeper`; public so a test (and an operator's
  `bin/vutuv rpc`) can run it directly.
  """
  def delete_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)
    {count, _} = Repo.delete_all(from(e in AccountEvent, where: e.inserted_at < ^cutoff))
    count
  end

  @doc """
  Every event of one member as plain maps, for the GDPR export. The whole row,
  because all of it is already the member's own data — and the log answering
  "what happened to my account" is exactly the kind of record Art. 20 is about.
  """
  def export(%User{id: user_id}) do
    Repo.all(
      from(e in AccountEvent,
        where: e.user_id == ^user_id,
        order_by: [asc: e.inserted_at, asc: e.id],
        select: %{
          at: e.inserted_at,
          kind: e.kind,
          factor: e.factor,
          device: e.device,
          by_someone_else: not is_nil(e.actor_user_id),
          details: e.details
        }
      )
    )
  end

  # ── Query building ──

  # `user_id` nil is the admin page's "every member" scope.
  defp base(user_id, filters) do
    from(e in AccountEvent, as: :event)
    |> scope_user(user_id)
    |> filter_kind(Map.get(filters, :kind))
    |> filter_member(Map.get(filters, :member))
    |> search(Map.get(filters, :q))
  end

  defp scope_user(query, nil), do: query
  defp scope_user(query, user_id), do: where(query, [event: e], e.user_id == ^user_id)

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, [event: e], e.kind == ^kind)

  defp filter_member(query, nil), do: query

  defp filter_member(query, term) do
    like = contains(term)

    query
    |> join_member()
    |> where(
      [member: m],
      ilike(m.username, ^like) or ilike(m.first_name, ^like) or ilike(m.last_name, ^like) or
        exists(
          from(email in Vutuv.Accounts.Email,
            where: email.user_id == parent_as(:member).id and ilike(email.value, ^like),
            select: 1
          )
        )
    )
  end

  defp search(query, nil), do: query

  defp search(query, term) do
    like = contains(term)

    where(
      query,
      [event: e],
      ilike(e.kind, ^like) or ilike(e.device, ^like) or ilike(e.factor, ^like) or
        ilike(fragment("CAST(? AS text)", e.details), ^like)
    )
  end

  defp contains(term), do: SearchText.contains(String.trim(term))

  # The member join is shared by the member filter and the member sort, and must
  # be added at most once — `has_named_binding?/2` is what keeps a filtered AND
  # member-sorted admin view from joining `users` twice.
  defp join_member(query) do
    if has_named_binding?(query, :member),
      do: query,
      else: join(query, :inner, [event: e], m in User, on: m.id == e.user_id, as: :member)
  end

  defp preload_actor(query), do: preload(query, [:actor_user])

  # The row's own id is the last key of every sort: it is a UUID v7, so it
  # encodes creation order, which keeps offset pagination stable when the
  # visible values tie (a burst of events of the same kind).
  defp order(query, filters) do
    dir = direction(Map.get(filters, :dir))

    case Map.get(filters, :sort) do
      "kind" ->
        order_by(query, [event: e], [{^dir, e.kind}, desc: e.inserted_at, desc: e.id])

      "member" ->
        query
        |> join_member()
        |> order_by([event: e, member: m], [
          {^dir, m.username},
          desc: e.inserted_at,
          desc: e.id
        ])

      _time ->
        # inserted_at has microsecond resolution, so ties are all but
        # impossible; the id tiebreaker still points the same way, keeping the
        # order total and paging deterministic.
        order_by(query, [event: e], [{^dir, e.inserted_at}, {^dir, e.id}])
    end
  end

  defp direction("asc"), do: :asc
  defp direction(_desc), do: :desc

  defp validated_sort(sort, allowed) when is_binary(sort) do
    if sort in allowed, do: sort, else: "time"
  end

  defp validated_sort(_sort, _allowed), do: "time"

  defp validated_dir(dir) when dir in ~w(asc desc), do: dir
  defp validated_dir(_other), do: nil

  defp validated_kind(kind) when is_binary(kind) do
    if kind?(kind), do: kind, else: nil
  end

  defp validated_kind(_other), do: nil
end
