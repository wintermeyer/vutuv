defmodule Vutuv.Organizations do
  @moduledoc """
  Verified organization pages (issue #929). An organization page can only exist once a
  member proved control of its web domain, so this context is organised around
  that trust model: a claim creates a `pending` organization plus an unverified
  primary `OrganizationDomain`; a successful proof (`Vutuv.Organizations.Verification`)
  flips it to `active` and stamps `verified_at`. DNS / well-known domains are
  re-checked periodically with a grace window before losing verified status.

  Engagement (like + bookmark) reuses `Vutuv.Engagement`; visibility, roles and
  the public directory live here too. Moderation freeze is applied by
  `Vutuv.Moderation` (which sets `organizations.frozen_at`); this context reads it
  in `organization_visible_to?/2`.
  """

  import Ecto.Query, warn: false
  import Vutuv.Moderation.Query, only: [account_confirmed_row: 1, account_hidden_row: 1]
  import Vutuv.Organizations.Query, only: [organization_public_row: 1]
  import Vutuv.SearchText, only: [contains: 1, normalize_search: 1]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Engagement
  alias Vutuv.Fediverse
  alias Vutuv.Handles
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationBookmark
  alias Vutuv.Organizations.OrganizationDomain
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Organizations.OrganizationLike
  alias Vutuv.Organizations.OrganizationName
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Organizations.Verification
  alias Vutuv.Pages
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostMention
  alias Vutuv.Posts.PostReply
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.SlugHelpers
  alias Vutuv.WebVerification

  # The role vocabulary, taken from the schema so the two can never disagree.
  # It has to be an attribute rather than a call because `add_role/4` guards on
  # it, and a guard cannot call a remote function.
  @roles OrganizationRole.roles()

  # Slugs that would shadow a /organizations/<word> route.
  @reserved_slugs ~w(new)
  @directory_per_page 24
  @people_per_page 24
  # The re-check interval and the grace window come from `Vutuv.WebVerification`,
  # shared with the profile-link and social-account re-checks: how long a
  # vanished proof keeps its mark is a promise to the member, and three copies of
  # "7 days" is three chances for the three features to drift apart.

  # How often a domain that is still waiting for its proof is looked at, by how
  # long ago the claim was started: `{claim younger than, check every}` in
  # seconds (issue #1466). Somebody who has just been shown the record is
  # publishing it right now, so the first quarter of an hour is checked hard and
  # the ladder then flattens out. Past the last step the claim is abandoned
  # rather than swept for ever — the owner can still press "Verify now", which
  # is what they will do if they ever come back to it.
  @pending_backoff [
    {900, 120},
    {7_200, 600},
    {86_400, 3_600},
    {30 * 86_400, 6 * 3_600}
  ]
  # The smallest interval on the ladder and the age past its last step, both
  # derived so the SQL prefilter and the ladder cannot drift apart.
  @pending_min_interval @pending_backoff |> Enum.map(&elem(&1, 1)) |> Enum.min()
  @pending_abandon_after @pending_backoff |> List.last() |> elem(0)
  # Rows read per pass, and how many of them are actually checked. The scan is
  # oldest-checked-first, so the rows most likely to be due come first and a
  # pass never walks the whole table.
  @pending_scan 200
  @pending_batch 50

  @doc """
  The canonical URL path of an organization page: its opt-in root handle when claimed
  (`/:username`, issue #941), otherwise `/organizations/:slug`. The one definition
  shared by the profile's work-experience link (issue #931), the agent docs and
  the sitemap, so a link never points at a non-canonical URL.
  """
  def canonical_path(%Organization{username: username}) when is_binary(username),
    do: "/" <> username

  def canonical_path(%Organization{slug: slug}), do: "/organizations/#{slug}"

  # --- fetch ------------------------------------------------------------------

  def get_organization(id), do: Repo.get(Organization, id)
  def get_organization!(id), do: Repo.get!(Organization, id)

  def get_organization_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(Organization, slug: slug)

  def get_organization_by_slug(_), do: nil

  @doc """
  The **publicly visible** organizations holding any of `usernames`, as a map
  keyed by the lowercase handle — the batched lookup behind linking `@acme` in
  a body (issue #1336), the organization twin of
  `Vutuv.Accounts.get_users_by_usernames/1`.

  One query per rendered body, never one per mention. A page that is pending,
  frozen or archived is simply absent, so the mention stays plain text rather
  than linking somewhere a reader cannot go.
  """
  def get_organizations_by_usernames(usernames) when is_list(usernames) do
    case usernames |> Enum.map(&String.downcase/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        from(o in Organization,
          where: o.username in ^names,
          where: organization_public_row(o),
          select: struct(o, [:id, :name, :slug, :username])
        )
        |> Repo.all()
        |> Map.new(&{&1.username, &1})
    end
  end

  @doc "Fetches an organization by its opt-in root handle (issue #941), or nil."
  def get_organization_by_username(username) when is_binary(username),
    do: Repo.get_by(Organization, username: username)

  def get_organization_by_username(_), do: nil

  @doc """
  Fetches an organization by its root handle (issue #941) if `viewer` may see it, the
  handle-namespace twin of `fetch_visible_organization/2`. Returns
  `{:error, :not_found}` for an unknown handle or a page hidden from `viewer`.
  """
  def fetch_visible_organization_by_username(username, viewer) do
    case get_organization_by_username(username) do
      nil ->
        {:error, :not_found}

      organization ->
        if organization_visible_to?(organization, viewer),
          do: {:ok, organization},
          else: {:error, :not_found}
    end
  end

  @doc """
  Fetches an active, non-frozen organization by slug for a public viewer, or the
  page for an owner/admin who may see it while `pending`/`frozen`. Returns
  `{:error, :not_found}` otherwise.
  """
  def fetch_visible_organization(slug, viewer) do
    case get_organization_by_slug(slug) do
      nil ->
        {:error, :not_found}

      organization ->
        if organization_visible_to?(organization, viewer),
          do: {:ok, organization},
          else: {:error, :not_found}
    end
  end

  @doc "Whether `viewer` may see `organization` at all (public active page, or owner/admin)."
  def organization_visible_to?(%Organization{} = organization, viewer) do
    public_visible?(organization) or can_manage?(organization, viewer) or admin?(viewer)
  end

  @doc "Whether `organization` is on the public site (active and not frozen)."
  def public_visible?(%Organization{status: "active", frozen_at: nil}), do: true
  def public_visible?(_), do: false

  @doc "Whether the page appears in machine channels (sitemap, JSON-LD): active + seo?."
  def indexable?(%Organization{seo?: true} = organization), do: public_visible?(organization)
  def indexable?(_), do: false

  @doc "Whether the agent-format siblings (.md/.txt/.json/.xml) are served: active + geo?."
  def agent_visible?(%Organization{geo?: true} = organization), do: public_visible?(organization)
  def agent_visible?(_), do: false

  # --- roles ------------------------------------------------------------------
  #
  # Powers (issues #930, #1333): owner = roles + domains + page + job postings;
  # admin = page + job postings; recruiter = job postings only; publisher =
  # speaking in the organization's name (its posts) and nothing administrative.
  # Every role is a proof-derived power, not an employment claim.
  #
  # A member may hold several roles and the effective powers are the union, but
  # `publisher` is never implied by another role — see `publisher?/2`.

  @doc """
  Whether `user` is organization staff (creator or any role holder). This is the
  *visibility* predicate — a recruiter still sees a pending/frozen page — not
  the edit predicate; use `can_edit_page?/2` / `owner?/2` for writes.
  """
  def can_manage?(%Organization{} = organization, %User{} = user) do
    organization.created_by_user_id == user.id or role_holder?(organization.id, user.id)
  end

  def can_manage?(_, _), do: false

  @doc ~S"""
  Every role `user` holds on `organization`, ranked owner → admin → recruiter,
  as a list of strings (`[]` for a non-member).

  This replaced `role_of/2`, which answered with a single role string, when
  issue #1333 let a member hold several roles at once. It was **renamed** rather
  than quietly changed: a permission accessor whose return type moves from
  `"owner" | nil` to a list under the same name is how a check ends up reading a
  non-empty list as truthy and waving everyone through.
  """
  def roles_of(%Organization{id: id}, %User{id: user_id}) do
    Repo.all(
      from(r in OrganizationRole,
        where: r.organization_id == ^id and r.user_id == ^user_id,
        select: r.role
      )
    )
    |> rank_roles()
  end

  def roles_of(_, _), do: []

  @doc "The role vocabulary, ranked owner → admin → publisher → recruiter."
  def roles, do: rank_roles(@roles)

  @doc "Sorts a list of role strings into the canonical owner → admin → publisher → recruiter order."
  def rank_roles(roles), do: Enum.sort_by(roles, &role_rank/1)

  @doc "Whether `user` is an owner of `organization` (manage roles + domains)."
  def owner?(%Organization{} = organization, %User{} = user),
    do: "owner" in roles_of(organization, user)

  def owner?(_, _), do: false

  @doc "Whether `user` may edit the organization page + aliases (owner or admin)."
  def can_edit_page?(%Organization{} = organization, %User{} = user),
    do: Enum.any?(roles_of(organization, user), &(&1 in ["owner", "admin"]))

  def can_edit_page?(_, _), do: false

  @doc """
  Whether `user` may speak in `organization`'s name: publish, edit and delete
  its posts, and switch into it (issue #1335).

  Deliberately **not** implied by `owner` or `admin`. That is the entire point of
  the role: administering a page and speaking for it are different powers, and
  a freshly claimed page therefore cannot post until its owner grants this once,
  which is a visible step rather than a silent default. The separation holds
  structurally rather than by convention, because `can_manage_roles?/2` is
  owner-only — an admin cannot grant themselves the right to post.
  """
  def publisher?(%Organization{} = organization, %User{} = user),
    do: "publisher" in roles_of(organization, user)

  def publisher?(_, _), do: false

  @doc """
  Every permission answer for one `(organization, viewer)` pair, from a single
  read of the role table.

  The four predicates above each run their own query, which is right for a
  caller with one question and wrong for a page that asks them all: the
  organization page asked five times (`owner?/2` twice), so one row set cost
  five round trips. They stay the public API; this is for the caller that wants
  the whole answer.

  `can_manage?` keeps its `created_by_user_id` leg — the member who claimed the
  page can always reach its settings, role row or not.
  """
  def role_powers(%Organization{} = organization, %User{} = user) do
    roles = roles_of(organization, user)

    %{
      roles: roles,
      owner?: "owner" in roles,
      can_edit?: Enum.any?(roles, &(&1 in ["owner", "admin"])),
      publisher?: "publisher" in roles,
      can_manage?: organization.created_by_user_id == user.id or roles != []
    }
  end

  def role_powers(_, _),
    do: %{roles: [], owner?: false, can_edit?: false, publisher?: false, can_manage?: false}

  @doc """
  Enables or disables Mastodon-compatible clients for one organization.

  A kill switch, not a role: it says whether this page may be reached through a
  phone client at all, and answers no for everybody the moment it is off, even
  the Redaktion. Who may act *through* that channel stays `publisher?/2`.
  """
  def set_mastodon_clients(%Organization{} = organization, enabled?) when is_boolean(enabled?) do
    organization
    |> Ecto.Changeset.change(mastodon_clients?: enabled?)
    |> Repo.update()
  end

  @doc """
  The organization `user` is currently acting as, given the id their session
  carries — or `nil` (issue #1335).

  **This is re-asked on every request and every socket mount, and the session's
  value is never trusted on its own.** The session is signed but not encrypted
  and stays valid for days, so a captured payload replays; that is the trap
  #1034 and #1036 already cost. Two things follow from asking live rather than
  from a stored claim: a withdrawn `publisher` role takes effect on the member's
  very next action instead of at their next login, and a page that is frozen,
  archived or otherwise no longer public stops being speakable-for at once.
  """
  def acting_organization(%User{} = user, organization_id) when is_binary(organization_id) do
    case get_organization(organization_id) do
      %Organization{} = organization ->
        if publisher?(organization, user) and organization_visible_to?(organization, user),
          do: organization,
          else: nil

      _ ->
        nil
    end
  end

  def acting_organization(_user, _organization_id), do: nil

  @doc """
  The organizations `user` may switch into (issue #1335): the pages they hold
  the `publisher` role on and may see, by name. Powers the identity menu.
  """
  def actable_organizations(%User{id: user_id} = user) do
    Repo.all(
      from(r in OrganizationRole,
        join: o in Organization,
        on: o.id == r.organization_id,
        where: r.user_id == ^user_id and r.role == "publisher",
        order_by: [asc: fragment("lower(?)", o.name)],
        select: o
      )
    )
    |> Enum.filter(&organization_visible_to?(&1, user))
  end

  def actable_organizations(_user), do: []

  @doc "Whether `user` may manage the roster (owner only)."
  def can_manage_roles?(organization, user), do: owner?(organization, user)

  @doc "Whether `user` may manage domains (owner only)."
  def can_manage_domains?(organization, user), do: owner?(organization, user)

  @doc """
  The active, non-frozen organizations `user` may post a job for (holds any role
  or created the page). Powers the job-posting editor's attribution select.
  """
  def postable_organizations(%User{id: user_id}) do
    Repo.all(
      from(o in Organization,
        left_join: r in OrganizationRole,
        on: r.organization_id == o.id and r.user_id == ^user_id,
        where:
          organization_public_row(o) and
            (o.created_by_user_id == ^user_id or not is_nil(r.id)),
        distinct: true,
        order_by: [asc: o.name]
      )
    )
  end

  @doc """
  Every organization the member helps run, as `{organization, roles}` pairs
  ordered by name, where `roles` is the ranked list of every role they hold
  there. Covers each page the member holds any role on — the claim wizard always
  makes the creator an `owner`, so a member's own pages are included too.
  **Pending** pages (still finishing domain verification) and **frozen** ones are
  kept so the member can act on them; **archived** pages are dropped. Powers the
  member's "Your organizations" page at `/settings/organizations` (distinct from
  `postable_organizations/1`, which is the active-only job-posting attribution
  set).
  """
  def member_organizations(%User{id: user_id}) do
    Repo.all(
      from(r in OrganizationRole,
        join: o in Organization,
        on: o.id == r.organization_id,
        where: r.user_id == ^user_id and o.status != "archived",
        order_by: [asc: fragment("lower(?)", o.name), asc: o.id],
        select: {o, r.role}
      )
    )
    |> Enum.chunk_by(fn {organization, _role} -> organization.id end)
    |> Enum.map(fn [{organization, _} | _] = rows ->
      {organization, rank_roles(Enum.map(rows, fn {_, role} -> role end))}
    end)
  end

  @doc """
  An organization's role rows, ranked owner → admin → publisher → recruiter and
  then oldest first, user preloaded. A member holding two roles appears twice —
  this is the raw row listing (the admin drawer reads it); the roster UI wants
  one entry per member and uses `list_team/1`.
  """
  def list_roles(%Organization{id: id}) do
    Repo.all(from(r in OrganizationRole, where: r.organization_id == ^id, preload: [:user]))
    |> Enum.sort_by(&{role_rank(&1.role), &1.id})
  end

  @doc """
  An organization's team, **one entry per member**: `%{user:, roles:, since:}`
  with `roles` ranked, ordered by the member's highest role and then by when
  they joined the team. This is what the roster renders, because with several
  roles per member a row-per-role list would show the same person twice with
  half their powers in each row.
  """
  def list_team(%Organization{} = organization) do
    organization
    |> list_roles()
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {_user_id, [first | _] = rows} ->
      %{
        user: first.user,
        roles: rank_roles(Enum.map(rows, & &1.role)),
        since: Enum.min_by(rows, & &1.id).id
      }
    end)
    |> Enum.sort_by(&{role_rank(hd(&1.roles)), &1.since})
  end

  defp role_rank("owner"), do: 0
  defp role_rank("admin"), do: 1
  defp role_rank("publisher"), do: 2
  defp role_rank("recruiter"), do: 3
  defp role_rank(_), do: 4

  # --- the page's own activity (issue #1336) ------------------------------
  #
  # What happened TO the page: somebody followed it, or liked or reposted
  # something it published. Derived from the source tables the way
  # `Vutuv.Activity` derives a member's notifications, so nothing has to be
  # written twice and an event disappears with the row behind it — an unliked
  # post is not "read", it simply never happened.
  #
  # The read marker is ONE timestamp on the page (`activity_read_at`), shared
  # by the whole team. That is the model the issue asks for and it is a
  # different one, not a wider one: "read" means somebody read it, never that
  # everybody did.

  @activity_per_page 25

  @doc """
  One page of `organization`'s activity, newest first, in the
  `%{entries:, more?:}` shape. Each entry is
  `%{id:, kind:, at:, actor:, post: }` — `kind` one of `"follow"`,
  `"post_like"`, `"post_repost"`, `"mention"`, `"reply"`; `post` nil on a follow,
  and on a `"reply"` it is the **answer** (what the team wants to read), not the
  post of the page's that was answered.
  """
  def activity_page(%Organization{} = organization, opts \\ []) do
    limit = Keyword.get(opts, :limit, @activity_per_page)
    offset = Keyword.get(opts, :offset, 0)

    page =
      Vutuv.FeedPage.paginate_offset(
        [
          &activity_follows(organization, &1, &2),
          &activity_post_engagement(organization, PostLike, "post_like", &1, &2),
          &activity_post_engagement(organization, PostRepost, "post_repost", &1, &2),
          &activity_mentions(organization, &1, &2),
          &activity_replies(organization, &1, &2)
        ],
        limit,
        offset
      )

    %{entries: page.entries, more?: page.more?, next_offset: offset + length(page.entries)}
  end

  @doc """
  How many activity entries are newer than the team's shared read marker,
  capped so a page nobody has looked at in a year does not turn the badge into
  a census. `nil` marker means everything counts, which is right for a page
  whose team has never opened the list.
  """
  def unread_activity_count(%Organization{} = organization) do
    organization
    |> activity_page(limit: @activity_per_page)
    |> Map.fetch!(:entries)
    |> Enum.count(&newer_than_marker?(&1, organization.activity_read_at))
  end

  defp newer_than_marker?(_entry, nil), do: true

  defp newer_than_marker?(%{at: at}, read_at),
    do: NaiveDateTime.compare(at, read_at) == :gt

  @doc """
  Fills in `activity_unread` on each page of a `{organization, roles}` list —
  the member's own "Your organizations" listing and nothing else.

  Deliberately per page rather than one clever batched query: a member helps
  run a handful of pages, this is a settings page and not a hot path, and the
  shared read marker lives on each row so a batched version would have to carry
  three per-organization joins to save queries nobody is counting.
  """
  def with_activity_unread(entries) do
    Enum.map(entries, fn {organization, roles} ->
      {%{organization | activity_unread: unread_activity_count(organization)}, roles}
    end)
  end

  @doc """
  Stamps the shared read marker. Whoever on the team opens the list clears it
  for all of them — that is the point of one marker.

  The marker is the timestamp of the **newest entry**, not the wall clock, for
  the same reason `Vutuv.Activity.mark_notifications_read/1` does it that way:
  the source tables keep second precision and the unread test is a strict `>`,
  so a wall-clock marker swallows anything that lands in the same second the
  page was opened.

  An **empty** list stamps nothing at all and leaves the marker NULL, which is
  where this parts company with the member version. There the clock is written
  because a NULL marker would read as "never read"; here NULL and a stamp
  behave identically while the list is empty (both count zero), and NULL is
  strictly better the moment something arrives — a follow one second after the
  team looked at an empty page is news, and a wall-clock marker would have
  swallowed it.
  """
  def mark_activity_read(%Organization{} = organization) do
    case activity_page(organization, limit: 1) do
      %{entries: [%{at: at} | _]} ->
        organization |> Ecto.Changeset.change(activity_read_at: at) |> Repo.update()

      _ ->
        {:ok, organization}
    end
  end

  # Members who followed the page.
  defp activity_follows(%Organization{id: id}, fetch_n, _cursor) do
    from(f in Vutuv.Social.Follow,
      join: u in User,
      on: u.id == f.follower_id,
      where: f.followee_organization_id == ^id,
      where: account_confirmed_row(u) and not account_hidden_row(u),
      order_by: [desc: f.inserted_at, desc: f.id],
      limit: ^fetch_n,
      select: {f.id, f.inserted_at, u}
    )
    |> Repo.all()
    |> Enum.map(fn {id, at, actor} ->
      %{id: "follow-#{id}", kind: "follow", at: at, actor: actor, post: nil}
    end)
  end

  # Posts that named the page by its root handle (issue #1336). Read off the
  # `post_mentions` rows `Vutuv.Posts` reconciles at save time, so an edit that
  # drops the mention drops the entry with it.
  #
  # The page's OWN posts are excluded: a page naming itself is not news to its
  # team, and every organization post already sits on the page above.
  defp activity_mentions(%Organization{id: id}, fetch_n, _cursor) do
    from(m in PostMention,
      join: p in Post,
      on: p.id == m.post_id,
      # Inner join, so a mention written BY another organization's page is not
      # listed. Accepted for now: a page cannot yet name another page (its
      # composer has no mention flow of its own), so there is nothing to miss.
      join: u in User,
      on: u.id == p.user_id,
      where: m.organization_id == ^id,
      where: account_confirmed_row(u) and not account_hidden_row(u),
      where: is_nil(p.frozen_at),
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^fetch_n,
      select: {m.id, m.inserted_at, u, p}
    )
    |> Repo.all()
    |> Enum.map(fn {row_id, at, actor, post} ->
      # `Vutuv.Posts.path/1` matches on the preloaded author, so the post has to
      # carry one or the link raises rather than renders. Here the actor IS that
      # author (the join is on `p.user_id`), so no query and no `preload:` —
      # which a tuple `select` could not have carried anyway.
      post = %{post | user: actor}
      %{id: "mention-#{row_id}", kind: "mention", at: at, actor: actor, post: post}
    end)
  end

  # Somebody answered one of the page's posts (issue #1336). This is the source
  # that receives a reply, and its existence is what made answering a page's post
  # allowed at all: `Vutuv.Posts.broadcast_reply/2` writes no notification for a
  # page, because there is no member to address and a row written per publisher
  # would contradict the one shared read marker.
  #
  # Read off `post_replies.parent_organization_id`, the page-shaped half of the
  # pair `Vutuv.Activity` reads as `parent_author_id` for a member — deliberately
  # not by joining the answered post, which nilifies away when the page deletes
  # it: "somebody answered you" stays news even then, exactly as it does for a
  # member.
  #
  # `post` is the **answer**: the team wants to read what was written, and the
  # post of theirs it hangs under is one click further on (the answer's card
  # carries its own "Replying to …" line). The reply's author is always a member,
  # so the join to `users` is an inner one by nature rather than by oversight — a
  # page cannot answer anything.
  defp activity_replies(%Organization{id: id}, fetch_n, _cursor) do
    from(r in PostReply,
      join: p in Post,
      on: p.id == r.post_id,
      join: u in User,
      on: u.id == p.user_id,
      where: r.parent_organization_id == ^id,
      where: account_confirmed_row(u) and not account_hidden_row(u),
      where: not p.images_pending? and is_nil(p.frozen_at),
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^fetch_n,
      select: {r.id, r.inserted_at, u, p}
    )
    |> Repo.all()
    |> Enum.map(fn {row_id, at, actor, post} ->
      # Same reason as the mentions above: `Vutuv.Posts.path/1` reads the
      # preloaded author, and here the actor IS that author (the join is on
      # `p.user_id`), so no query and no `preload:`.
      post = %{post | user: actor}
      %{id: "reply-#{row_id}", kind: "reply", at: at, actor: actor, post: post}
    end)
  end

  # Likes and reposts of the page's own posts. One function for both because
  # the two tables are the same shape and the only difference is the word.
  defp activity_post_engagement(
         %Organization{id: id} = organization,
         schema,
         kind,
         fetch_n,
         _cursor
       ) do
    from(e in schema,
      join: p in Post,
      on: p.id == e.post_id,
      join: u in User,
      on: u.id == e.user_id,
      where: p.organization_id == ^id,
      where: account_confirmed_row(u) and not account_hidden_row(u),
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^fetch_n,
      select: {e.id, e.inserted_at, u, p}
    )
    |> Repo.all()
    |> Enum.map(fn {row_id, at, actor, post} ->
      # Same reason as above, without the query: these are the page's OWN
      # posts, and the caller is holding the page.
      post = %{post | organization: organization}
      %{id: "#{kind}-#{row_id}", kind: kind, at: at, actor: actor, post: post}
    end)
  end

  @doc """
  Up to six member suggestions for the roles typeahead, matched by `@handle` or
  name, excluding the ids in `exclude` (the current role holders). Returns `[]`
  for a term shorter than two characters.
  """
  def suggest_members(term, exclude \\ []) do
    trimmed = term |> to_string() |> String.trim() |> String.trim_leading("@")

    if String.length(trimmed) < 2 do
      []
    else
      like = contains(trimmed)

      Repo.all(
        from(u in User,
          where:
            u.id not in ^exclude and account_confirmed_row(u) and not account_hidden_row(u) and
              (ilike(u.username, ^like) or ilike(u.first_name, ^like) or ilike(u.last_name, ^like)),
          order_by: [asc: u.username],
          limit: 6
        )
      )
    end
  end

  @doc """
  Grants `user` one role on `organization`. Notifies the member (the derived
  notification feed picks up the row; a live push updates the badge). Returns
  `{:ok, role}`, `{:error, :already_member}` when they already hold **that**
  role, or `{:error, changeset}`.
  """
  def add_role(%Organization{} = organization, %User{} = user, role, %User{} = granted_by)
      when role in @roles do
    %OrganizationRole{}
    |> OrganizationRole.changeset(%{
      organization_id: organization.id,
      user_id: user.id,
      role: role,
      granted_by_user_id: granted_by.id
    })
    |> Repo.insert()
    |> case do
      {:ok, role_row} ->
        Vutuv.Activity.notify_organization_role(user.id, granted_by, organization, role)
        {:ok, role_row}

      {:error, %{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :organization_id) or Keyword.has_key?(errors, :user_id),
          do: {:error, :already_member},
          else: {:error, changeset}
    end
  end

  @doc """
  Sets the complete set of roles `user` holds on `organization` — the checkbox
  roster's one operation, and the successor to the old single-role
  `update_role/3`. An empty list removes them from the team.

  Adds what is missing, removes what is no longer ticked, leaves the rest
  untouched (so an unchanged role keeps its `granted_by` and its age), and
  notifies the member once per newly granted role. Returns `{:ok, roles}` with
  the ranked new set, or `{:error, :last_owner}` when the change would leave the
  organization without an owner.

  Taking `owner` away runs under the same `guard_last_owner/2` row lock the
  single-role path used: two concurrent edits each dropping a *different* owner
  could otherwise both read "there are two owners" and both commit, leaving zero.
  """
  def set_roles(%Organization{} = organization, %User{} = user, roles, %User{} = actor) do
    wanted = roles |> Enum.filter(&(&1 in @roles)) |> Enum.uniq()
    held = roles_of(organization, user)

    cond do
      MapSet.new(wanted) == MapSet.new(held) ->
        {:ok, rank_roles(held)}

      "owner" in held and "owner" not in wanted ->
        guard_last_owner(organization.id, fn ->
          apply_role_set(organization, user, wanted, held, actor)
        end)

      true ->
        apply_role_set(organization, user, wanted, held, actor)
    end
  end

  defp apply_role_set(organization, user, wanted, held, actor) do
    granted = wanted -- held
    revoked = held -- wanted

    Repo.delete_all(
      from(r in OrganizationRole,
        where:
          r.organization_id == ^organization.id and r.user_id == ^user.id and r.role in ^revoked
      )
    )

    Enum.each(granted, fn role ->
      %OrganizationRole{}
      |> OrganizationRole.changeset(%{
        organization_id: organization.id,
        user_id: user.id,
        role: role,
        granted_by_user_id: actor.id
      })
      |> Repo.insert(on_conflict: :nothing)

      Vutuv.Activity.notify_organization_role(user.id, actor, organization, role)
    end)

    {:ok, rank_roles(wanted)}
  end

  @doc """
  Removes a role (an owner removing a member, or a member leaving). Refuses to
  remove the last owner (an organization always keeps ≥ 1 owner).
  """
  def remove_role(%OrganizationRole{role: "owner"} = role_row) do
    guard_last_owner(role_row.organization_id, fn -> Repo.delete(role_row) end)
  end

  def remove_role(%OrganizationRole{} = role_row), do: Repo.delete(role_row)

  # Runs `fun` (an owner demotion / removal) only if the org would keep >= 1
  # owner, with the owner rows locked FOR UPDATE for the whole transaction so two
  # concurrent last-owner checks can't both pass. Returns `{:ok, result}`,
  # `{:error, :last_owner}`, or `fun`'s own `{:error, _}`.
  defp guard_last_owner(organization_id, fun) do
    Repo.transaction(fn ->
      if last_owner_locked?(organization_id),
        do: Repo.rollback(:last_owner),
        else: run_or_rollback(fun)
    end)
  end

  # Locks the org's owner rows FOR UPDATE (so a concurrent demotion blocks and
  # re-reads) and reports whether removing one would drop below one owner.
  defp last_owner_locked?(organization_id) do
    owners =
      Repo.all(
        from(r in OrganizationRole,
          where: r.organization_id == ^organization_id and r.role == "owner",
          lock: "FOR UPDATE"
        )
      )

    length(owners) <= 1
  end

  defp run_or_rollback(fun) do
    case fun.() do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp role_holder?(organization_id, user_id) do
    Repo.exists?(
      from(r in OrganizationRole,
        where: r.organization_id == ^organization_id and r.user_id == ^user_id
      )
    )
  end

  defp admin?(%User{admin?: true}), do: true
  defp admin?(_), do: false

  # --- claim + create ---------------------------------------------------------

  @doc "A blank create changeset for the claim wizard form."
  def change_new_organization(attrs \\ %{}),
    do: Organization.create_changeset(%Organization{}, attrs)

  @doc "An edit changeset for the owner form."
  def change_organization(%Organization{} = organization, attrs \\ %{}),
    do: Organization.edit_changeset(organization, attrs)

  @doc """
  Creates a `pending` organization from the claim wizard: the organization + an owner
  role + an unverified primary domain (derived from the website URL, using the
  chosen `method`). Returns `{:ok, %{organization: c, domain: d}}`,
  `{:error, :domain_taken}` when the domain already belongs to another organization,
  or `{:error, changeset}`.
  """
  def create_pending_organization(%User{} = user, attrs, method)
      when method in ~w(dns well_known) do
    changeset =
      %Organization{created_by_user_id: user.id, status: "pending"}
      |> Organization.create_changeset(attrs)
      |> require_website()

    if changeset.valid? do
      do_create_pending(user, changeset, method)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp require_website(changeset) do
    case Ecto.Changeset.get_field(changeset, :website_url) do
      nil -> Ecto.Changeset.add_error(changeset, :website_url, "is required to verify the domain")
      _ -> changeset
    end
  end

  defp do_create_pending(user, changeset, method) do
    name = Ecto.Changeset.get_field(changeset, :name)

    slug =
      SlugHelpers.gen_slug_unique(
        String.slice(name, 0, 120),
        Organization,
        :slug,
        @reserved_slugs
      )

    host = OrganizationDomain.normalize(Ecto.Changeset.get_field(changeset, :website_url))
    token = Verification.gen_token()

    organization_changeset =
      changeset
      |> Ecto.Changeset.put_change(:slug, slug)
      |> Ecto.Changeset.validate_length(:slug, max: 255)
      |> Ecto.Changeset.unique_constraint(:slug)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:organization, organization_changeset)
    |> Ecto.Multi.insert(:role, fn %{organization: organization} ->
      OrganizationRole.changeset(%OrganizationRole{}, %{
        organization_id: organization.id,
        user_id: user.id,
        role: "owner",
        granted_by_user_id: user.id
      })
    end)
    |> Ecto.Multi.insert(:domain, fn %{organization: organization} ->
      OrganizationDomain.changeset(%OrganizationDomain{}, %{
        organization_id: organization.id,
        domain: host,
        primary?: true,
        method: method,
        verification_token: token
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: _, domain: _} = result} -> {:ok, result}
      {:error, :domain, _changeset, _} -> {:error, :domain_taken}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  # --- owner edit -------------------------------------------------------------

  @doc """
  Applies the owner/admin edit form; keeps the slug stable (renames keep the
  URL). A rename auto-appends the old name as a `former` alias, so the rename
  history is data, not a log file (issue #930).
  """
  def update_organization(%Organization{} = organization, attrs) do
    changeset = Organization.edit_changeset(organization, attrs)
    old_name = organization.name

    Ecto.Multi.new()
    |> Ecto.Multi.update(:organization, changeset)
    |> Ecto.Multi.run(:former_alias, fn _repo, %{organization: updated} ->
      if updated.name != old_name, do: record_former_alias(updated, old_name), else: {:ok, nil}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: updated}} -> {:ok, updated}
      {:error, :organization, changeset, _} -> {:error, changeset}
      {:error, _step, _reason, _} -> {:error, %{changeset | action: :update}}
    end
  end

  @doc """
  Claims (or changes) the organization's opt-in root handle (issue #941): validates
  the grammar, then upserts the `handles` registry row in the same transaction,
  so a handle already held by a member or another organization loses on the unique
  index and comes back as a `:username` changeset error. Owner-only — the caller
  gates on `owner?/2`.
  """
  # Only a verified, live page earns a global root handle. A pending (never
  # domain-proven) org must not lock a handle it can't prove it controls — that
  # is cheap, repeatable namespace squatting against the registry's UNIQUE(value).
  def claim_handle(%Organization{status: status}, _attrs) when status != "active",
    do: {:error, :not_verified}

  def claim_handle(%Organization{} = organization, attrs) do
    changeset = Organization.handle_changeset(organization, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:organization, changeset)
    |> Ecto.Multi.run(:handle, fn repo, %{organization: updated} ->
      Handles.put_organization_handle(repo, updated)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: updated}} ->
        # The @name is the last thing a page needs to federate, so claiming one
        # is the moment a wizard opt-in becomes real — and the moment the
        # keypair has to exist. A federating page without one has its deliveries
        # deleted as undeliverable, with no error anywhere (the member twin of
        # this is `Accounts.activate_user/1`, which mints on confirmation for
        # the same reason). Minted here rather than lazily on the first request,
        # so a remote server that resolves the handle a second later finds a
        # complete actor instead of waiting on an RSA keygen.
        if Fediverse.federated?(updated), do: Fediverse.ensure_organization_actor(updated)

        {:ok, updated}

      {:error, :organization, changeset, _} ->
        {:error, changeset}

      {:error, :handle, _handle_changeset, _} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(:username, "has already been taken")
         |> Map.put(:action, :update)}
    end
  end

  # --- verification -----------------------------------------------------------

  @doc "All of an organization's domains, primary first. An organization has very few."
  def list_domains(%Organization{id: id}) do
    Repo.all(
      from(d in OrganizationDomain,
        where: d.organization_id == ^id,
        order_by: [desc: d.primary?, asc: d.inserted_at]
      )
    )
  end

  @doc "The primary (claim) domain of an organization."
  def primary_domain(%Organization{} = organization),
    do: Enum.find(list_domains(organization), & &1.primary?)

  @doc "An organization's currently verified domains, primary first."
  def verified_domains(%Organization{} = organization),
    do: Enum.filter(list_domains(organization), & &1.verified_at)

  @doc """
  Adds a second (or further) domain to an organization (issue #930): a non-primary,
  not-yet-verified `OrganizationDomain` derived from `url`, using `method`. The owner
  finishes it with the #929 verification wizard on the domains page (which flips
  it to verified without touching the organization status). Returns `{:ok, domain}`,
  `{:error, :domain_taken}` when the host already belongs to an organization, or
  `{:error, changeset}`.
  """
  def add_domain(%Organization{} = organization, url, method) when method in ~w(dns well_known) do
    host = OrganizationDomain.normalize(url)

    %OrganizationDomain{}
    |> OrganizationDomain.changeset(%{
      organization_id: organization.id,
      domain: host,
      primary?: false,
      method: method,
      verification_token: Verification.gen_token()
    })
    |> Repo.insert()
    |> case do
      {:ok, domain} -> {:ok, domain}
      {:error, changeset} -> {:error, domain_error(changeset)}
    end
  end

  # A unique-constraint hit on the host means it belongs to another organization; any
  # other error is a plain validation failure (returned as the changeset).
  defp domain_error(changeset) do
    taken? =
      Enum.any?(changeset.errors, fn
        {:domain, {_msg, opts}} -> opts[:constraint] == :unique
        _ -> false
      end)

    if taken?, do: :domain_taken, else: changeset
  end

  @doc "Fetches one domain row scoped to an organization (owner-management actions)."
  def get_domain(%Organization{id: id}, domain_id) do
    Repo.one(
      from(d in OrganizationDomain, where: d.organization_id == ^id and d.id == ^domain_id)
    )
  end

  @doc """
  Removes a domain. Refuses to remove the organization's **last verified** domain
  (every active organization keeps ≥ 1, like the last owner). Removing the primary
  auto-promotes the oldest remaining verified domain, so the badge follows.
  """
  def remove_domain(%Organization{} = organization, %OrganizationDomain{} = domain) do
    if domain.verified_at && verified_domain_count(organization.id) <= 1 do
      {:error, :last_domain}
    else
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.delete!(domain)
          if domain.primary?, do: promote_new_primary(organization.id)
        end)

      {:ok, organization}
    end
  end

  # Makes the oldest remaining verified domain the new primary.
  defp promote_new_primary(organization_id) do
    Repo.one(
      from(d in OrganizationDomain,
        where: d.organization_id == ^organization_id and not is_nil(d.verified_at),
        order_by: [asc: d.inserted_at],
        limit: 1
      )
    )
    |> case do
      nil -> :ok
      domain -> Repo.update!(Ecto.Changeset.change(domain, primary?: true))
    end
  end

  @doc """
  Picks the domain shown in the \"Verifiziert über …\" badge. Only a verified
  domain can be primary. Flips atomically (old primary off, then new on) so the
  one-primary partial unique index is never violated mid-write.
  """
  def set_primary_domain(%Organization{} = organization, %OrganizationDomain{} = domain) do
    cond do
      is_nil(domain.verified_at) ->
        {:error, :not_verified}

      domain.primary? ->
        {:ok, domain}

      true ->
        {:ok, updated} =
          Repo.transaction(fn ->
            Repo.update_all(
              from(d in OrganizationDomain,
                where: d.organization_id == ^organization.id and d.primary?
              ),
              set: [primary?: false]
            )

            Repo.update!(Ecto.Changeset.change(domain, primary?: true))
          end)

        {:ok, updated}
    end
  end

  defp verified_domain_count(organization_id) do
    Repo.aggregate(
      from(d in OrganizationDomain,
        where: d.organization_id == ^organization_id and not is_nil(d.verified_at)
      ),
      :count,
      :id
    )
  end

  @doc "The TXT value a member must publish for DNS verification."
  def dns_txt_value(%OrganizationDomain{verification_token: token}),
    do: Verification.dns_txt_value(token)

  @doc """
  The CNAME-safe alternate name (`_vutuv.<domain>`) the DNS TXT record may also
  live at, for a domain that is itself a CNAME.
  """
  def dns_challenge_name(%OrganizationDomain{domain: host}),
    do: Verification.dns_challenge_name(host)

  @doc "The well-known file URL and content for the `well_known` method."
  def well_known_url(%OrganizationDomain{domain: host}), do: Verification.well_known_url(host)
  def well_known_content(%OrganizationDomain{verification_token: token}), do: token

  @doc "Whether domain verification (DNS TXT + well-known) is enabled for this install."
  def verification_enabled?, do: Verification.enabled?()

  @doc "Switches a pending domain between the DNS and well-known methods (same token)."
  def set_domain_method(%OrganizationDomain{} = domain, method)
      when method in ~w(dns well_known) do
    domain |> Ecto.Changeset.change(method: method) |> Repo.update()
  end

  @doc """
  Runs the domain's proof and **says what it saw** (issue #1466):
  `{:ok, organization}` once the page is live, or `{:error, report}` with the
  names queried, the value we wanted and the records actually found — the
  difference between "not yet" and "you published it one label too deep".

  This is the **only** way to run a domain's proof. It replaced a second
  entry point (`verify_domain/2` and its per-method twins) that answered a bare
  `{:error, :not_found}` and stamped nothing: two functions for one question is
  how the next caller silently gets no report and no `last_checked_at`, which
  the background pass reads to back off.

  `report.disabled?` marks the one case that is not about the domain at all:
  domain verification is switched off on this installation.
  """
  def check_domain(%Organization{} = organization, %OrganizationDomain{} = domain) do
    if verification_enabled?() do
      domain |> run_check() |> record_check(organization, domain)
    else
      {:error, %{method: domain.method, disabled?: true}}
    end
  end

  defp run_check(%OrganizationDomain{method: "dns"} = domain),
    do: Verification.dns_check(domain.domain, domain.verification_token)

  defp run_check(%OrganizationDomain{method: "well_known"} = domain),
    do: Verification.well_known_check(domain.domain, domain.verification_token)

  defp record_check({:ok, _report}, organization, domain), do: activate(organization, domain)

  defp record_check({:error, report}, _organization, domain) do
    domain
    |> OrganizationDomain.check_changeset(%{last_checked_at: now()})
    |> Repo.update()

    {:error, Map.put(report, :disabled?, false)}
  end

  # Flips a pending organization to active off a freshly verified domain, stamps
  # verified_at once, and alerts the operator on first verification.
  defp activate(%Organization{} = organization, %OrganizationDomain{} = domain) do
    now = now()
    first? = is_nil(organization.verified_at)

    organization_changeset =
      organization
      |> Organization.status_changeset("active")
      |> then(fn cs ->
        if first?, do: Ecto.Changeset.put_change(cs, :verified_at, now), else: cs
      end)

    {:ok, %{organization: organization, domain: domain}} =
      Ecto.Multi.new()
      |> Ecto.Multi.update(
        :domain,
        OrganizationDomain.check_changeset(domain, %{
          verified_at: now,
          last_checked_at: now,
          grace_deadline_at: nil
        })
      )
      |> Ecto.Multi.update(:organization, organization_changeset)
      |> Repo.transaction()

    if first? do
      organization
      |> Emailer.organization_verified_notice(domain)
      |> Emailer.deliver()
    end

    {:ok, organization}
  end

  # --- finishing a claim in the background (issue #1466) ----------------------
  #
  # Until this existed, a pending domain was checked exactly when somebody
  # pressed the button and never otherwise: `domains_due_for_recheck/1` below
  # only guards domains that are already verified. So a member who published the
  # record and closed the tab was never verified, and nothing on the page told
  # them that clicking again was the only way. These two functions are the other
  # half of that promise, and the mail on success is what lets them close the
  # tab at all.

  @doc """
  Pending domains that are due for a background check: never verified, the claim
  not yet abandoned, and last looked at longer ago than the backoff step its age
  puts it on.

  The interval is applied in memory because it depends on the row's own age; the
  query narrows to rows that could possibly be due (the shortest step) and reads
  them oldest-checked-first, so the ones most likely due are at the front.
  """
  def pending_domains_due(now \\ NaiveDateTime.utc_now()) do
    now = NaiveDateTime.truncate(now, :second)
    abandoned_before = NaiveDateTime.add(now, -@pending_abandon_after)
    checked_before = NaiveDateTime.add(now, -@pending_min_interval)

    from(d in OrganizationDomain,
      where:
        d.method in ["dns", "well_known"] and is_nil(d.verified_at) and
          d.inserted_at > ^abandoned_before and
          (is_nil(d.last_checked_at) or d.last_checked_at < ^checked_before),
      order_by: [asc_nulls_first: d.last_checked_at, asc: d.id],
      limit: @pending_scan,
      preload: [:organization]
    )
    |> Repo.all()
    |> Enum.filter(&pending_due?(&1, now))
    |> Enum.take(@pending_batch)
  end

  @doc """
  Checks every due pending domain and returns how many pages went live this
  pass. No-op when network verification is disabled.
  """
  def check_pending_domains do
    if verification_enabled?() do
      pending_domains_due()
      |> Task.async_stream(&check_pending_domain/1,
        max_concurrency: 10,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.count(fn {:ok, outcome} -> outcome == :verified end)
    else
      0
    end
  end

  defp check_pending_domain(%OrganizationDomain{} = domain) do
    organization = organization_of(domain)

    # `check_domain/2` stamps `last_checked_at` on the failing branch too, so a
    # domain whose record is still missing leaves the due set for this step's
    # interval instead of holding the front of every batch.
    case check_domain(organization, domain) do
      {:ok, organization} ->
        notify_owners_of_verified(organization, domain)
        broadcast_verified(organization)
        :verified

      {:error, _report} ->
        :pending
    end
  end

  # `pending_domains_due/0` preloads the organization, so a full batch of 50
  # costs one query and not fifty; the lookup stays as the answer for a domain
  # that reached here another way.
  defp organization_of(%OrganizationDomain{organization: %Organization{} = organization}),
    do: organization

  defp organization_of(%OrganizationDomain{organization_id: id}), do: get_organization!(id)

  defp pending_due?(%OrganizationDomain{} = domain, now) do
    case pending_interval(NaiveDateTime.diff(now, domain.inserted_at)) do
      :abandoned ->
        false

      interval ->
        is_nil(domain.last_checked_at) or
          NaiveDateTime.diff(now, domain.last_checked_at) >= interval
    end
  end

  defp pending_interval(age_in_seconds) do
    Enum.find_value(@pending_backoff, :abandoned, fn {younger_than, interval} ->
      age_in_seconds < younger_than && interval
    end)
  end

  defp notify_owners_of_verified(organization, domain) do
    notify_owners(organization, fn user, address ->
      Emailer.organization_domain_verified_email(user, address, organization, domain)
    end)
  end

  # --- periodic re-check ------------------------------------------------------

  @doc "DNS / well-known domains whose last check is older than the interval."
  def domains_due_for_recheck(now \\ NaiveDateTime.utc_now()) do
    cutoff = WebVerification.recheck_cutoff(now)

    Repo.all(
      from(d in OrganizationDomain,
        where:
          d.method in ["dns", "well_known"] and not is_nil(d.verified_at) and
            (is_nil(d.last_checked_at) or d.last_checked_at < ^cutoff)
      )
    )
  end

  @doc """
  Re-checks all due DNS / well-known domains (called by the sweeper). No-op when
  network verification is disabled. Returns the count of domains that lost
  verified status this run.
  """
  def recheck_due_domains do
    if verification_enabled?() do
      # Each check does one blocking DNS / HTTP call (no DB connection held
      # during it), so run them with bounded concurrency instead of summing
      # every domain's network latency serially.
      domains_due_for_recheck()
      |> Task.async_stream(&recheck_domain/1,
        max_concurrency: 10,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.count(fn {:ok, outcome} -> outcome in [:demoted_domain, :demoted_organization] end)
    else
      0
    end
  end

  @doc """
  Re-checks one domain. On success refreshes `last_checked_at` and clears any
  grace window. On failure starts a grace window, waits it out, then demotes the
  domain (and the organization, if it was its last verified domain, alerting the
  operator). Returns an outcome atom.
  """
  def recheck_domain(%OrganizationDomain{} = domain) do
    now = now()

    verified? =
      case domain.method do
        "dns" ->
          Verification.dns_verified?(domain.domain, domain.verification_token)

        "well_known" ->
          Verification.well_known_verified?(domain.domain, domain.verification_token)

        _ ->
          true
      end

    if verified? do
      domain
      |> OrganizationDomain.check_changeset(%{last_checked_at: now, grace_deadline_at: nil})
      |> Repo.update()

      :ok
    else
      handle_recheck_failure(domain, now)
    end
  end

  defp handle_recheck_failure(domain, now) do
    case WebVerification.grace_step(domain.grace_deadline_at, now) do
      {:grace_started, deadline} ->
        {:ok, domain} =
          domain
          |> OrganizationDomain.check_changeset(%{
            last_checked_at: now,
            grace_deadline_at: deadline
          })
          |> Repo.update()

        # The one moment the owners can still prevent the outage: warn them now,
        # once per window (the `:in_grace` arm below stays silent, so a weekly
        # re-check does not nag them into ignoring the mail).
        notify_owners_of_grace(domain)

        :grace_started

      :in_grace ->
        domain
        |> OrganizationDomain.check_changeset(%{last_checked_at: now})
        |> Repo.update()

        :in_grace

      :demote ->
        demote_domain(domain, now)
    end
  end

  defp demote_domain(domain, now) do
    was_primary = domain.primary?

    changeset =
      domain
      |> OrganizationDomain.check_changeset(%{
        verified_at: nil,
        last_checked_at: now,
        grace_deadline_at: nil
      })

    # check_changeset can't cast primary?, so clear it here (put_change bypasses
    # cast): a demoted primary must not keep a false "verified via <domain>"
    # badge. Clearing it in the same write also frees the one-primary partial
    # unique index before we promote a replacement below.
    changeset =
      if was_primary, do: Ecto.Changeset.put_change(changeset, :primary?, false), else: changeset

    {:ok, domain} = Repo.update(changeset)

    organization = get_organization!(domain.organization_id)

    if verified_domain_count(organization.id) == 0 do
      {:ok, organization} =
        organization |> Organization.status_changeset("pending") |> Repo.update()

      organization
      |> Emailer.organization_unverified_notice(domain)
      |> Emailer.deliver()

      # The operator hears about it above; the owners are the ones who have to
      # act, so they hear about it too.
      notify_owners_of_unverified(organization, domain)

      :demoted_organization
    else
      # A non-last domain was dropped: the page stays verified via its others,
      # but the operator is still alerted (issue #930). If the demoted domain was
      # the primary, move the badge to a still-verified one.
      if was_primary, do: promote_new_primary(organization.id)

      organization
      |> Emailer.organization_domain_dropped_notice(domain)
      |> Emailer.deliver()

      :demoted_domain
    end
  end

  # --- owner notices ----------------------------------------------------------
  #
  # The operator notices above tell the *installation operator* that a page
  # changed state. They deliberately link to /admin/organizations, which the
  # page's own staff cannot even open — so on their own they leave the one
  # person who can republish the proof in the dark. These are the member-facing
  # twins. Recipients are the **owners**: domains are an owner-only power
  # (`can_manage_domains?/2`), so an admin or recruiter would get a call to
  # action they cannot follow.

  defp notify_owners_of_grace(domain) do
    organization = get_organization!(domain.organization_id)
    last? = verified_domain_count(organization.id) <= 1

    notify_owners(organization, fn user, address ->
      Emailer.organization_domain_grace_email(user, address, organization, domain, last?)
    end)
  end

  defp notify_owners_of_unverified(organization, domain) do
    notify_owners(organization, fn user, address ->
      Emailer.organization_page_unverified_email(user, address, organization, domain)
    end)
  end

  # Mails every owner at their first address, each in their own locale (the
  # builder picks the template by `user.locale`). An owner without a usable
  # address is simply skipped.
  defp notify_owners(organization, build) do
    organization
    |> owners()
    |> Enum.each(fn user ->
      case Accounts.first_email_value(user) do
        nil -> :ok
        address -> user |> build.(address) |> Emailer.deliver()
      end
    end)
  end

  @doc """
  The members who may manage `organization`'s domains, oldest role first. The
  claim wizard makes the creator an owner, so this is never empty for a page
  that went through it.
  """
  def owners(%Organization{id: id}) do
    Repo.all(
      from(r in OrganizationRole,
        join: u in User,
        on: u.id == r.user_id,
        where: r.organization_id == ^id and r.role == "owner",
        order_by: [asc: r.id],
        select: u
      )
    )
  end

  # --- engagement (like + bookmark) ------------------------------------------

  # The Engagement fabric config: the fk doubles as the payload id key, and
  # the two tuple names are pattern-matched by OrganizationLive.Show and
  # PostLive.Saved — a rename is a breaking contract change.
  @engagement_cfg %{
    fk: :organization_id,
    like_schema: OrganizationLike,
    topic_prefix: "organization",
    counters_msg: :organization_counters,
    changed_msg: :organization_engagement_changed
  }

  def like_organization(%User{} = user, %Organization{} = organization),
    do: Engagement.engage(OrganizationLike, :like, user.id, organization.id, @engagement_cfg)

  def unlike_organization(%User{} = user, %Organization{} = organization),
    do: Engagement.disengage(OrganizationLike, :like, user.id, organization.id, @engagement_cfg)

  def bookmark_organization(%User{} = user, %Organization{} = organization),
    do:
      Engagement.engage(
        OrganizationBookmark,
        :bookmark,
        user.id,
        organization.id,
        @engagement_cfg
      )

  def unbookmark_organization(%User{} = user, %Organization{} = organization),
    do:
      Engagement.disengage(
        OrganizationBookmark,
        :bookmark,
        user.id,
        organization.id,
        @engagement_cfg
      )

  @doc """
  Flips one engagement `kind` off its current state (the
  `%{liked?:, bookmarked?:}` map `organization_engagement/2` returns; nil
  reads as unengaged) — the jobs twin lives in `Vutuv.Jobs.toggle_engagement/4`.
  """
  def toggle_engagement(:like, user, organization, %{liked?: true}),
    do: unlike_organization(user, organization)

  def toggle_engagement(:like, user, organization, _), do: like_organization(user, organization)

  def toggle_engagement(:bookmark, user, organization, %{bookmarked?: true}),
    do: unbookmark_organization(user, organization)

  def toggle_engagement(:bookmark, user, organization, _),
    do: bookmark_organization(user, organization)

  @doc """
  Public like count plus the viewer's own `liked?`/`bookmarked?` flags for the
  action bar. An anonymous viewer gets `false` flags.
  """
  def organization_engagement(%Organization{id: organization_id}, viewer) do
    Engagement.subject_engagement(OrganizationBookmark, organization_id, viewer, @engagement_cfg)
  end

  @doc "Subscribes to an organization's live counter topic."
  def subscribe(organization_id), do: Engagement.subscribe(organization_id, @engagement_cfg)

  # Tells an open page that the background pass finished its claim, so somebody
  # who published the record and left the tab sitting there watches it go live
  # instead of reloading to find out (issue #1466). Lives here rather than with
  # the pending pass above because `@engagement_cfg` owns the topic name.
  defp broadcast_verified(%Organization{id: id}) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      Engagement.topic(id, @engagement_cfg),
      {:organization_verified, id}
    )
  end

  @doc """
  One page of the member's liked / bookmarked organizations for the `/bookmarks`
  saved-items hub, honoring its search (`name`/`city`) and sort. Returns
  `%{entries:, more?:, next_offset:}` (offset pagination), like the posts pages.
  """
  def saved_organizations_page(%User{id: user_id}, kind, opts) when kind in [:like, :bookmark] do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    search = normalize_search(opts[:search])
    schema = if kind == :like, do: OrganizationLike, else: OrganizationBookmark

    query =
      from(c in Organization,
        join: e in ^schema,
        as: :engagement,
        on: e.organization_id == c.id,
        where: e.user_id == ^user_id and organization_public_row(c)
      )

    query = if search, do: name_or_city_ilike(query, search), else: query

    entries =
      query
      |> saved_order(opts[:sort])
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> select([c], c)
      |> Repo.all()

    Pages.offset_page(entries, limit, offset)
  end

  defp saved_order(query, :oldest), do: order_by(query, [engagement: e], asc: e.inserted_at)
  defp saved_order(query, :name), do: order_by(query, [c], asc: fragment("lower(?)", c.name))
  defp saved_order(query, _recent), do: order_by(query, [engagement: e], desc: e.inserted_at)

  # --- aliases (organization_names) ------------------------------------------------
  #
  # Alternative names an organization is findable under (issue #930): the directory and
  # admin search match names AND aliases. A collision with another verified
  # organization's name/alias is stored but flagged for the admin queue (no
  # user-facing warning — identical organization names are common and legitimate).

  @doc "An organization's alternative names, newest kind-grouped, for the edit + admin views."
  def list_aliases(%Organization{id: id}) do
    Repo.all(
      from(n in OrganizationName, where: n.organization_id == ^id, order_by: [asc: n.inserted_at])
    )
  end

  @doc "Fetches one alias row scoped to an organization (owner/admin edit)."
  def get_alias(%Organization{id: id}, alias_id) do
    Repo.one(from(n in OrganizationName, where: n.organization_id == ^id and n.id == ^alias_id))
  end

  @doc """
  Adds an alias (kind `alias`/`brand`/`abbreviation`; `former` is minted by a
  rename). Stored even on a collision, but stamped `flagged_at` for the admin
  queue when equal (case-insensitive) to another verified organization's name or
  alias. Returns `{:ok, organization_name}` or `{:error, changeset}` (a duplicate on
  this organization hits the unique index).
  """
  def add_alias(%Organization{} = organization, name, kind \\ "alias") do
    flagged_at = if alias_collision?(organization.id, name), do: now()

    %OrganizationName{}
    |> OrganizationName.changeset(%{
      organization_id: organization.id,
      name: name,
      kind: kind,
      flagged_at: flagged_at
    })
    |> Repo.insert()
  end

  @doc "Removes an alias."
  def remove_alias(%OrganizationName{} = organization_name), do: Repo.delete(organization_name)

  # Records the old name as a `former` alias on rename (idempotent — skips if the
  # name is already listed), flagging collisions like any other alias.
  defp record_former_alias(%Organization{} = organization, old_name) do
    if is_binary(old_name) and String.trim(old_name) != "" and
         not alias_exists?(organization.id, old_name) do
      add_alias(organization, old_name, "former")
    else
      {:ok, nil}
    end
  end

  defp downcase_name(name), do: name |> to_string() |> String.trim() |> String.downcase()

  defp alias_exists?(organization_id, name) do
    down = downcase_name(name)

    Repo.exists?(
      from(n in OrganizationName,
        where: n.organization_id == ^organization_id and fragment("lower(?)", n.name) == ^down
      )
    )
  end

  # Whether `name` equals (case-insensitive) another **verified** (active)
  # organization's name or any of its aliases. Deliberately NOT
  # `organization_public_row/1`: a frozen page keeps `status: "active"` and its
  # name stays taken while it is hidden.
  defp alias_collision?(organization_id, name) do
    down = downcase_name(name)

    name_hit? =
      Repo.exists?(
        from(c in Organization,
          where:
            c.id != ^organization_id and c.status == "active" and
              fragment("lower(?)", c.name) == ^down
        )
      )

    name_hit? or
      Repo.exists?(
        from(n in OrganizationName,
          join: c in Organization,
          on: c.id == n.organization_id,
          where:
            n.organization_id != ^organization_id and c.status == "active" and
              fragment("lower(?)", n.name) == ^down
        )
      )
  end

  @doc "How many aliases are flagged for the admin queue (a collision guardrail hit)."
  def flagged_aliases_count do
    Repo.aggregate(from(n in OrganizationName, where: not is_nil(n.flagged_at)), :count, :id)
  end

  @doc "Fetches one alias row by id for the admin queue, or nil."
  def get_alias(id), do: Vutuv.UUIDv7.with_cast(id, &Repo.get(OrganizationName, &1))

  @doc "Clears an alias's admin-queue flag (a human reviewed it and it is fine)."
  def clear_alias_flag(%OrganizationName{} = organization_name),
    do: organization_name |> Ecto.Changeset.change(flagged_at: nil) |> Repo.update()

  # --- work-experience linking (issue #931) -----------------------------------
  #
  # A member may optionally link a work experience to a verified organization page.
  # The link is a display convenience, not a badge — the employment claim stays
  # self-asserted. Only a **verified** (active, non-frozen) organization is ever a
  # link target, so a frozen/archived page silently reverts every linked
  # experience to plain text.

  @doc "Fetches an active, non-frozen organization by id (a linkable target), or nil."
  def get_active_organization(id) when is_binary(id) do
    Repo.one(from(c in Organization, where: c.id == ^id and organization_public_row(c)))
  end

  def get_active_organization(_), do: nil

  @doc """
  The verified organization a member's free-text organization would link to: an
  active, non-frozen organization whose **name or an alias equals** the trimmed text
  case-insensitively. Exact equality, not a substring — the editor only suggests
  a link when the whole employer name matches, so "Acme" never volunteers "Acme
  Foundation". Returns the `%Organization{}` or nil (a term under two characters, or
  no match, yields nil). When several verified organizations legitimately share a
  name the oldest wins, so the suggestion is deterministic.
  """
  def suggest_organization_for_org(name) do
    down = downcase_name(name)

    if String.length(down) < 2 do
      nil
    else
      Repo.one(
        from(c in Organization,
          where: organization_public_row(c),
          where:
            fragment("lower(?)", c.name) == ^down or
              fragment(
                "EXISTS (SELECT 1 FROM organization_names cn WHERE cn.organization_id = ? AND lower(cn.name) = ?)",
                c.id,
                ^down
              ),
          order_by: [asc: c.inserted_at],
          limit: 1
        )
      )
    end
  end

  @doc """
  The number of members whose linked work experience is at `organization` and who are
  publicly listable (`Vutuv.Directory.indexable_users` semantics: confirmed, not
  search-opted-out, not moderation-hidden). The count the People section shows.
  """
  def organization_people_count(%Organization{id: id}) do
    people_base(id)
    |> select([_w, u], u.id)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  @doc """
  One page of `organization`'s **People**: members whose linked work experience is at
  this organization. Current members (an ongoing linked role, no end date) lead, then
  past members, each group by name; offset-paginated like the saved-items hub.

  Each entry is `%{user:, title:, current?:}` where `title` is the linked role's
  title **exactly as the member wrote it** (their most recent role at the
  organization). Privacy is the member-directory gate (`indexable_users` semantics),
  so a member who opted out of public listing or is moderation-hidden never
  appears — the same set the agent-format people list carries. Returns
  `%{entries:, more?:, next_offset:}`.
  """
  def organization_people_page(%Organization{id: organization_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, @people_per_page)
    offset = Keyword.get(opts, :offset, 0)

    rows =
      people_base(organization_id)
      |> select([w, u], %{user_id: u.id, current?: fragment("bool_or(? IS NULL)", w.end_year)})
      |> order_by([w, u], [
        {:desc, fragment("bool_or(? IS NULL)", w.end_year)},
        {:asc,
         fragment("lower(coalesce(nullif(trim(?), ''), ?, ''))", u.last_name, u.first_name)},
        {:asc, fragment("lower(coalesce(?, ''))", u.first_name)},
        {:asc, u.id}
      ])
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()

    page = Pages.offset_page(rows, limit, offset)

    ids = Enum.map(page.entries, & &1.user_id)
    users = ids |> load_people() |> Map.new(&{&1.id, &1})
    titles = representative_titles(organization_id, ids)

    entries =
      Enum.map(page.entries, fn row ->
        %{
          user: Map.fetch!(users, row.user_id),
          title: Map.get(titles, row.user_id),
          current?: row.current?
        }
      end)

    %{page | entries: entries}
  end

  # One row per listable member with a linked experience at the organization, grouped
  # so the current?/title aggregates collapse a member's several roles into one.
  defp people_base(organization_id) do
    from(w in WorkExperience,
      join: u in User,
      on: u.id == w.user_id,
      where:
        w.organization_id == ^organization_id and account_confirmed_row(u) and
          not u.noindex? and not account_hidden_row(u),
      group_by: u.id
    )
  end

  defp load_people(ids), do: Repo.all(from(u in User, where: u.id in ^ids))

  # The title each shown member is listed under: their most recent linked role at
  # the organization — an ongoing one wins, else the one with the latest end date.
  defp representative_titles(_organization_id, []), do: %{}

  defp representative_titles(organization_id, ids) do
    from(w in WorkExperience,
      where: w.organization_id == ^organization_id and w.user_id in ^ids,
      select: %{
        user_id: w.user_id,
        title: w.title,
        start_year: w.start_year,
        start_month: w.start_month,
        end_year: w.end_year,
        end_month: w.end_month
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {user_id, roles} -> {user_id, representative_title(roles)} end)
  end

  defp representative_title(roles) do
    chosen =
      case Enum.filter(roles, &is_nil(&1.end_year)) do
        [] ->
          Enum.max_by(
            roles,
            &{&1.end_year || 0, &1.end_month || 0, &1.start_year || 0, &1.start_month || 0}
          )

        ongoing ->
          Enum.max_by(ongoing, &{&1.start_year || 0, &1.start_month || 0})
      end

    chosen.title
  end

  # --- directory --------------------------------------------------------------

  @doc """
  A page of the public directory: active, non-frozen organizations, ordered by name,
  optionally filtered by a search over name AND city. Returns a map with
  `:entries`, `:page`, `:total_pages`, `:total`, `:per_page`.
  """
  def directory_page(opts \\ []) do
    search = normalize_search(opts[:search])
    query = directory_query(search)
    total = Repo.aggregate(query, :count, :id)
    total_pages = max(1, ceil(total / @directory_per_page))
    page = (opts[:page] || 1) |> max(1) |> min(total_pages)

    entries =
      query
      |> order_by([c], asc: fragment("lower(?)", c.name))
      |> limit(^@directory_per_page)
      |> offset(^((page - 1) * @directory_per_page))
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      total_pages: total_pages,
      total: total,
      per_page: @directory_per_page
    }
  end

  defp directory_query(nil),
    do: from(c in Organization, where: organization_public_row(c))

  defp directory_query(term), do: name_or_city_ilike(directory_query(nil), term)

  # Case-insensitive match on name, city OR any alias, LIKE wildcards escaped.
  defp name_or_city_ilike(query, term) do
    pattern = contains(term)

    from(c in query,
      where:
        ilike(c.name, ^pattern) or ilike(c.city, ^pattern) or
          fragment(
            "EXISTS (SELECT 1 FROM organization_names cn WHERE cn.organization_id = ? AND cn.name ILIKE ?)",
            c.id,
            ^pattern
          )
    )
  end

  @doc """
  The active + non-frozen + seo? organization set: the one definition of "indexable"
  shared by the sitemap (mirrors how `Sitemap` delegates the member set to
  `Vutuv.Directory`, so the two can never drift).
  """
  def indexable_query do
    from(c in Organization, where: organization_public_row(c) and c.seo?)
  end

  # --- admin dashboard (issue #930) -------------------------------------------

  @admin_per_page 25

  @doc "Overview tile counts for /admin/organizations (live / pending / frozen)."
  def admin_overview_counts do
    Repo.one(
      from(c in Organization,
        select: %{
          active: filter(count(c.id), organization_public_row(c)),
          pending: filter(count(c.id), c.status == "pending"),
          frozen: filter(count(c.id), not is_nil(c.frozen_at))
        }
      )
    )
  end

  @doc """
  A page of the admin organization list: filtered by `:status`
  (`active`/`pending`/`frozen`/`archived`/nil=all) and searched over name,
  city, alias AND domain. Newest first. Returns the same shape as
  `directory_page/1`.
  """
  def admin_organizations_page(opts \\ []) do
    search = normalize_search(opts[:search])

    query =
      from(c in Organization)
      |> admin_status_filter(opts[:status])
      |> then(&if search, do: admin_search(&1, search), else: &1)

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(1, ceil(total / @admin_per_page))
    page = (opts[:page] || 1) |> max(1) |> min(total_pages)

    entries =
      query
      |> order_by([c], desc: c.inserted_at)
      |> limit(^@admin_per_page)
      |> offset(^((page - 1) * @admin_per_page))
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      total_pages: total_pages,
      total: total,
      per_page: @admin_per_page
    }
  end

  # "frozen" cuts across status (a frozen page keeps status active); the others
  # are the status itself, excluding a frozen one so the chips don't double-count.
  defp admin_status_filter(query, "frozen"), do: where(query, [c], not is_nil(c.frozen_at))

  defp admin_status_filter(query, status) when status in ~w(active pending archived),
    do: where(query, [c], c.status == ^status and is_nil(c.frozen_at))

  defp admin_status_filter(query, _all), do: query

  defp admin_search(query, term) do
    pattern = contains(term)

    from(c in query,
      where:
        ilike(c.name, ^pattern) or ilike(c.city, ^pattern) or
          fragment(
            "EXISTS (SELECT 1 FROM organization_names cn WHERE cn.organization_id = ? AND cn.name ILIKE ?)",
            c.id,
            ^pattern
          ) or
          fragment(
            "EXISTS (SELECT 1 FROM organization_domains cd WHERE cd.organization_id = ? AND cd.domain ILIKE ?)",
            c.id,
            ^pattern
          )
    )
  end

  @doc "Everything the admin detail drawer shows for one organization, or nil."
  def admin_organization_detail(id) do
    case get_organization(id) do
      nil ->
        nil

      organization ->
        %{
          organization: organization,
          domains: list_domains(organization),
          roles: list_roles(organization),
          aliases: list_aliases(organization),
          claimed_by:
            organization.created_by_user_id &&
              Vutuv.Accounts.get_user(organization.created_by_user_id)
        }
    end
  end

  @doc """
  Turns federating on or off for a page (issue #1334). Owner's decision: it
  changes how the page appears on servers we do not run, and it cannot be fully
  undone — a copy another server already holds can only be asked to go.
  """
  def set_fediverse_opt_in(%Organization{} = organization, on?) when is_boolean(on?) do
    organization |> Ecto.Changeset.change(fediverse_followers?: on?) |> Repo.update()
  end

  @doc "Admin freeze/unfreeze: sets/clears `frozen_at` (same effect as the report freeze)."
  def admin_set_frozen(%Organization{} = organization, frozen?) do
    frozen_at = if frozen?, do: now()
    organization |> Ecto.Changeset.change(frozen_at: frozen_at) |> Repo.update()
  end

  @doc "Archives an organization page (hides it, keeps the record and its URL reserved)."
  def archive_organization(%Organization{} = organization) do
    organization |> Organization.status_changeset("archived") |> Repo.update()
  end

  @doc """
  Whether an organization page may be hard-deleted by its owner: a page with
  job postings (issue #932) must be archived instead, so the postings and
  their history survive. Admin oversight keeps its own unconditional delete.
  """
  def deletable?(%Organization{id: id}), do: not Vutuv.Jobs.any_for_organization?(id)

  # --- images -----------------------------------------------------------------

  def get_image_by_token(token) when is_binary(token),
    do: Repo.get_by(OrganizationImage, token: token)

  def get_image_by_token(_), do: nil

  @doc """
  Stores a new logo for `organization` (replacing any previous one): writes the
  derived versions, records a `OrganizationImage` row and points `organizations.logo` at
  its token. Returns `{:ok, organization}` or `{:error, :invalid_file}`.
  """
  def store_logo(%Organization{} = organization, %User{} = user, path, filename) do
    token = OrganizationImage.gen_token()

    case Vutuv.OrganizationImageStore.store(path, filename, token) do
      {:ok, meta} ->
        # A fresh logo starts in AI-moderation limbo. Unlike avatars, the
        # `organizations.logo` pointer only ever names a *released* image: it
        # flips to the new token when the scan approves (`release_logo/1`),
        # so the current logo keeps showing meanwhile and no template ever
        # renders an unreleased byte or a broken image.
        moderation = ImageScans.initial_state()

        {:ok, image} =
          Repo.insert(%OrganizationImage{
            organization_id: organization.id,
            user_id: user.id,
            token: token,
            width: meta.width,
            height: meta.height,
            content_type: meta.content_type,
            size_bytes: meta.size_bytes,
            moderation: moderation
          })

        if moderation == "approved" do
          release_logo(image)
        else
          ImageScans.enqueue("organization_image", image.id, user.id)
          {:ok, organization}
        end

      {:error, _reason} ->
        {:error, :invalid_file}
    end
  end

  @doc """
  Points `organizations.logo` at a (released) image and purges the logo it
  displaces. Called on store when moderation is off, and by the scan verdict
  (`Vutuv.Moderation.ImageSubjects`) when it is on. Assumes organization
  images are logos (true today — revisit when the #932-style description
  gallery lands on organization pages).
  """
  def release_logo(%OrganizationImage{} = image) do
    organization = Repo.get!(Organization, image.organization_id)
    old_token = organization.logo

    {:ok, organization} =
      organization |> Ecto.Changeset.change(logo: image.token) |> Repo.update()

    if old_token && old_token != image.token, do: purge_image(old_token, organization.id)
    {:ok, organization}
  end

  @doc "Removes an organization's logo (files + row + column)."
  def remove_logo(%Organization{logo: nil} = organization), do: {:ok, organization}

  def remove_logo(%Organization{logo: token} = organization) do
    {:ok, organization} = organization |> Ecto.Changeset.change(logo: nil) |> Repo.update()
    purge_image(token, organization.id)
    {:ok, organization}
  end

  defp purge_image(token, organization_id) do
    Repo.delete_all(
      from(i in OrganizationImage,
        where: i.token == ^token and i.organization_id == ^organization_id
      )
    )

    Vutuv.OrganizationImageStore.delete(token)
  end

  @doc "Whether an organization image may be served to `viewer` (public page or owner/admin)."
  def image_visible_to?(%OrganizationImage{organization_id: nil, user_id: user_id}, %User{
        id: user_id
      }),
      do: true

  def image_visible_to?(%OrganizationImage{organization_id: nil}, _viewer), do: false

  def image_visible_to?(%OrganizationImage{organization_id: organization_id} = image, viewer) do
    case get_organization(organization_id) do
      nil ->
        false

      organization ->
        # AI-moderation limbo: until released, the bytes are uploader/admin-only.
        organization_visible_to?(organization, viewer) and
          (ImageScans.released?(image.moderation) or ImageScans.privileged_viewer?(image, viewer))
    end
  end

  # --- deletion ---------------------------------------------------------------

  @doc """
  Deletes an organization and purges its on-disk image files. The DB cascade removes
  the domain/role/like/bookmark/image rows; only the files need explicit
  cleanup. Used by moderation/admin (organizations are never member-deleted here).
  """
  def delete_organization(%Organization{} = organization) do
    tokens = image_tokens(organization.id)
    logo_cover = Enum.reject([organization.logo, organization.cover], &is_nil/1)

    with {:ok, organization} <- Repo.delete(organization) do
      # Settle any open moderation case, then purge the on-disk image files (the
      # DB cascade already dropped the rows).
      Vutuv.Moderation.content_deleted(organization)
      for token <- Enum.uniq(tokens ++ logo_cover), do: Vutuv.OrganizationImageStore.delete(token)
      {:ok, organization}
    end
  end

  @doc "Every image token a member owns across organizations (for `Accounts.delete_user/1`)."
  def image_tokens_for_user(user_id) do
    Repo.all(from(i in OrganizationImage, where: i.user_id == ^user_id, select: i.token))
  end

  defp image_tokens(organization_id) do
    Repo.all(
      from(i in OrganizationImage, where: i.organization_id == ^organization_id, select: i.token)
    )
  end

  defp now, do: NaiveDateTime.utc_now(:second)
end
