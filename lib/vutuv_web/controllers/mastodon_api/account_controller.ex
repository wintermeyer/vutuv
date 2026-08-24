defmodule VutuvWeb.MastodonApi.AccountController do
  @moduledoc "The authenticated account identity expected after OAuth login."

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.MastodonApi.AccountCounts
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Profiles.VerifiedLinks
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Handles
  alias VutuvWeb.MastodonApi.Pagination

  def verify_credentials(conn, _params) do
    subject = conn.assigns.current_organization || conn.assigns.current_user

    json(conn, Presenter.account(with_links(subject), counts(conn, subject)))
  end

  @doc """
  The account a handle names (`GET /api/v1/accounts/lookup?acct=…`).

  A client calls this constantly — it is what resolves the `@handle` in a
  compose box, in a shared link and in a profile it was pointed at — and until
  now it fell through to the adapter's 404, so every one of those turned into a
  dead end although the member was right here. Local only, which is Mastodon's
  own contract for this endpoint (its WebFinger-free twin of search); see
  `VutuvWeb.MastodonApi.Handles`.
  """
  def lookup(conn, %{"acct" => acct}) do
    case Handles.local(conn, acct) do
      nil -> not_found(conn)
      account -> json(conn, Presenter.account(with_links(account), counts(conn, account)))
    end
  end

  def lookup(conn, _params), do: not_found(conn)

  def show(conn, %{"id" => id}) do
    case target(conn, id) do
      nil -> not_found(conn)
      account -> json(conn, Presenter.account(with_links(account), counts(conn, account)))
    end
  end

  # The three figures a client puts in a profile header, from the one place that
  # assembles them (`Vutuv.MastodonApi.AccountCounts`). They used to be composed
  # here as well as there, and the two copies had already drifted: a page's own
  # publisher counted as a publisher on this endpoint and as a stranger in the
  # account embedded in a status, so the same page reported two different post
  # counts depending on which object the client happened to read.
  # The viewer differs by subject and always has: a page's own publisher may see
  # its frozen posts, a member's profile is read as `profile_viewer/1` decides.
  # Only the *arithmetic* moved out; passing the viewer stays here, because this
  # is the only layer that knows which page the request is acting for.
  defp counts(conn, %Organization{} = page),
    do: AccountCounts.for_account(page, organization_viewer(conn, page))

  defp counts(conn, subject), do: AccountCounts.for_account(subject, profile_viewer(conn))

  def follow(conn, %{"id" => id}), do: relationship_action(conn, id, :follow)
  def unfollow(conn, %{"id" => id}), do: relationship_action(conn, id, :unfollow)
  def mute(conn, %{"id" => id}), do: relationship_action(conn, id, :mute)
  def unmute(conn, %{"id" => id}), do: relationship_action(conn, id, :unmute)
  def block(conn, %{"id" => id}), do: relationship_action(conn, id, :block)
  def unblock(conn, %{"id" => id}), do: relationship_action(conn, id, :unblock)

  # Deduplicated and capped, because this is the one endpoint here that takes a
  # list of ids and does per-id work: each one is a lookup plus a visibility
  # check, and each surviving row then costs a handful of relationship queries.
  # Left unbounded, a single request with a few hundred repeated ids is a
  # thousand queries somebody else's phone pays for — and repeating one id is
  # free to send and pointless to answer twice. The cap is the page size every
  # other list here is bounded by, so a client that wants more asks again.
  @max_relationships 40

  def relationships(conn, params) do
    relationships =
      params["id"]
      |> List.wrap()
      |> Enum.uniq()
      |> Enum.take(@max_relationships)
      |> Enum.map(&target(conn, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&relationship(conn, &1))

    json(conn, relationships)
  end

  def statuses(conn, %{"id" => id, "pinned" => pinned})
      when pinned in [true, "true", "1"] do
    # **`pinned=true` asks for the pinned post, not for the timeline.** It was
    # ignored, so a client showing an account's pinned row got the whole
    # timeline back and treated its newest entry as pinned — a member's only
    # post appeared "pinned" although they had never pinned anything. vutuv has
    # a real pin (`users.pinned_post_id`, issue #1110), so the honest answer is
    # that one post, or none. A page has no pin of its own, and neither does a
    # remote account we only cache, so both answer the empty list rather than
    # their newest post.
    posts =
      case target(conn, id) do
        %User{} = user -> user |> Posts.pinned_post(profile_viewer(conn)) |> List.wrap()
        _page_or_remote -> []
      end

    json(conn, Presenter.statuses(posts, viewer(conn)))
  end

  def statuses(conn, %{"id" => id} = params) do
    page = Pagination.params(params, strip: &bare_id/1)
    opts = Pagination.opts(page)

    statuses =
      case target(conn, id) do
        %User{} = user ->
          user
          |> Posts.author_statuses(profile_viewer(conn), opts)
          |> Presenter.statuses(viewer(conn))

        %Organization{} = organization ->
          organization
          |> Posts.organization_statuses(organization_viewer(conn, organization), opts)
          |> Presenter.statuses(viewer(conn))

        # The only source here that cannot be bounded in its query: what we
        # hold of a remote account is a bounded cache, not a list we can page
        # (`Fediverse.account_posts/2` answers everything it has). Cutting the
        # window out of it is honest for that reason and no other.
        %RemoteAccount{} = account ->
          subject = conn.assigns.current_organization || conn.assigns.current_user
          {posts, _more?} = Fediverse.account_posts(account, subject)

          # Through `statuses/2` like every other source here, not a bare
          # `status/1` per row: that is what batches the photographs these posts
          # carry (issue #1626). It costs nothing extra — the batches it runs
          # short-circuit on a page holding no local post.
          posts
          |> Pagination.window(page, & &1.id)
          |> Enum.map(&%{&1 | remote_account: account})
          |> Presenter.statuses(viewer(conn))

        _missing_or_unsupported ->
          []
      end

    conn
    |> Pagination.link_header(Enum.map(statuses, &bare_id(&1.id)), page)
    |> json(statuses)
  end

  def following(conn, %{"id" => id} = params) do
    page = Pagination.params(params, strip: &bare_id/1)

    opts = Pagination.opts(page)

    accounts =
      case {target(conn, id), conn.assigns.current_organization} do
        {%User{} = user, _identity} ->
          user_following(conn, user, opts)

        {%Organization{id: organization_id} = organization, %Organization{id: organization_id}} ->
          organization_following(organization, opts)

        _private_or_missing ->
          []
      end

    accounts =
      accounts
      |> Enum.map(&Presenter.account/1)
      |> Enum.uniq_by(& &1.id)
      # Newest first, like every other Mastodon list, so paging by id walks it
      # in one direction instead of jumping around the source order.
      |> Enum.sort_by(&bare_id(&1.id), :desc)
      |> Pagination.window(page, &bare_id(&1.id))

    conn
    |> Pagination.link_header(Enum.map(accounts, &bare_id(&1.id)), page)
    |> json(accounts)
  end

  defp relationship_action(conn, id, action) do
    case target(conn, id) do
      nil ->
        not_found(conn)

      target ->
        case apply_action(conn, target, action) do
          :ok -> json(conn, relationship(conn, target))
          {:ok, _value} -> json(conn, relationship(conn, target))
          {:error, reason} -> action_error(conn, reason)
          _other -> json(conn, relationship(conn, target))
        end
    end
  end

  defp apply_action(conn, %User{} = target, :follow) do
    case conn.assigns.current_organization do
      nil -> Social.follow(conn.assigns.current_user, target.id)
      organization -> Social.follow_as_organization(organization, target)
    end
  end

  defp apply_action(conn, %Organization{} = target, :follow) do
    case conn.assigns.current_organization do
      nil -> Social.follow_organization(conn.assigns.current_user, target)
      organization -> Social.follow_as_organization(organization, target)
    end
  end

  defp apply_action(conn, %RemoteAccount{} = target, :follow) do
    address = RemoteAccount.display_handle(target)

    case conn.assigns.current_organization do
      nil -> Fediverse.follow_remote(conn.assigns.current_user, address)
      organization -> Fediverse.follow_remote_as_organization(organization, address)
    end
  end

  defp apply_action(conn, %User{} = target, :unfollow) do
    case conn.assigns.current_organization do
      nil -> unfollow_member(conn.assigns.current_user, target)
      organization -> Social.unfollow_as_organization(organization, target)
    end
  end

  defp apply_action(conn, %Organization{} = target, :unfollow) do
    case conn.assigns.current_organization do
      nil -> Social.unfollow_organization(conn.assigns.current_user, target)
      organization -> Social.unfollow_as_organization(organization, target)
    end
  end

  defp apply_action(conn, %RemoteAccount{} = target, :unfollow) do
    case conn.assigns.current_organization do
      nil ->
        case Fediverse.remote_follow_for(conn.assigns.current_user, target) do
          nil -> :ok
          follow -> Fediverse.unfollow_remote(conn.assigns.current_user, follow.id)
        end

      organization ->
        case Fediverse.remote_follow_for(organization, target) do
          nil -> :ok
          follow -> Fediverse.unfollow_remote(organization, follow.id)
        end
    end
  end

  defp apply_action(conn, target, action) when action in [:mute, :unmute] do
    muted? = action == :mute

    case {conn.assigns.current_organization, target} do
      {nil, %RemoteAccount{id: id}} ->
        Fediverse.set_remote_follow_mute(conn.assigns.current_user, id, muted?)

      {%Organization{} = organization, %RemoteAccount{id: id}} ->
        Fediverse.set_remote_follow_mute(organization, id, muted?)

      {nil, local} ->
        Social.set_follow_mute(conn.assigns.current_user, local, muted?)

      {%Organization{} = organization, local} ->
        Social.set_follow_mute_as_organization(organization, local, muted?)
    end
  end

  defp apply_action(
         %{assigns: %{current_organization: nil, current_user: user}},
         %User{} = target,
         :block
       ),
       do: Social.block_user(user, target)

  defp apply_action(
         %{assigns: %{current_organization: nil, current_user: user}},
         %User{} = target,
         :unblock
       ),
       do: Social.unblock_user(user, target)

  defp apply_action(_conn, _target, action) when action in [:block, :unblock],
    do: {:error, :unsupported}

  defp unfollow_member(user, target) do
    case Social.follow_id(user.id, target.id) do
      nil ->
        :ok

      follow_id ->
        Social.unfollow!(user.id, follow_id)
        :ok
    end
  end

  defp relationship(conn, target) do
    following = following?(conn, target)

    %{
      id: Presenter.account(target).id,
      following: following,
      showing_reblogs: true,
      notifying: false,
      followed_by: followed_by?(conn, target),
      blocking: blocking?(conn, target),
      blocked_by: false,
      muting: muted?(conn, target),
      muting_notifications: false,
      requested: requested?(conn, target),
      domain_blocking: false,
      endorsed: false,
      note: "",
      languages: []
    }
  end

  defp following?(conn, %User{} = target) do
    case conn.assigns.current_organization do
      nil -> Social.user_follows_user?(conn.assigns.current_user.id, target.id)
      organization -> Social.organization_follows?(organization, target)
    end
  end

  defp following?(conn, %Organization{} = target) do
    case conn.assigns.current_organization do
      nil -> Social.follows_organization?(conn.assigns.current_user, target)
      organization -> Social.organization_follows?(organization, target)
    end
  end

  defp following?(conn, %RemoteAccount{} = target) do
    case conn.assigns.current_organization do
      nil -> not is_nil(Fediverse.remote_follow_for(conn.assigns.current_user, target))
      organization -> not is_nil(Fediverse.remote_follow_for(organization, target))
    end
  end

  defp followed_by?(
         %{assigns: %{current_organization: nil, current_user: user}},
         %User{} = target
       ),
       do: Social.user_follows_user?(target.id, user.id)

  defp followed_by?(_conn, _target), do: false

  defp blocking?(%{assigns: %{current_organization: nil, current_user: user}}, %User{} = target),
    do: MapSet.member?(Social.blocked_user_ids(user.id), target.id)

  defp blocking?(_conn, _target), do: false

  defp muted?(conn, %RemoteAccount{} = target) do
    follow =
      case conn.assigns.current_organization do
        nil -> Fediverse.remote_follow_for(conn.assigns.current_user, target)
        organization -> Fediverse.remote_follow_for(organization, target)
      end

    muted_follow?(follow)
  end

  defp muted?(conn, %User{} = target) do
    case conn.assigns.current_organization do
      nil ->
        muted_local_member?(conn.assigns.current_user.id, target.id)

      organization ->
        muted_follow?(Social.organization_follow_as_organization(organization, target))
    end
  end

  defp muted?(conn, %Organization{} = target) do
    case conn.assigns.current_organization do
      nil ->
        muted_follow?(Social.organization_follow(conn.assigns.current_user.id, target.id))

      organization ->
        muted_follow?(Social.organization_follow_as_organization(organization, target))
    end
  end

  defp muted_local_member?(user_id, target_id) do
    case Social.follow_edge(user_id, target_id) do
      %{muted?: muted?} -> muted?
      nil -> false
    end
  end

  defp muted_follow?(%{muted: muted?}), do: muted?
  defp muted_follow?(_missing), do: false

  defp requested?(conn, %RemoteAccount{} = target) do
    follow =
      case conn.assigns.current_organization do
        nil -> Fediverse.remote_follow_for(conn.assigns.current_user, target)
        organization -> Fediverse.remote_follow_for(organization, target)
      end

    match?(%{state: "requested"}, follow)
  end

  defp requested?(_conn, _target), do: false

  # Three kinds of account, three id spaces, so no one query can order them —
  # this is a merged list, and `Pagination.window/3` picks the page out of what
  # the sources return. The two local sources are bounded by the **same**
  # window first, so their read stays one page wide however deep the walk has
  # gone; taking the newest `limit` of each is enough, because the newest
  # `limit` overall cannot contain a row that was not among its own source's
  # newest `limit`. The remote leg is the member's own follow list, read whole
  # as it always has been — it has no keyset reader yet, and it is the one
  # source whose size a member sets themselves.
  defp user_following(conn, user, opts) do
    local_members = Social.follow_accounts(user, :followees, opts)
    local_organizations = Social.followed_organization_accounts(user, opts)

    remote_accounts =
      if is_nil(conn.assigns.current_organization) and conn.assigns.current_user.id == user.id,
        do: user |> Fediverse.list_remote_follows() |> Enum.map(& &1.remote_account),
        else: []

    local_members ++ local_organizations ++ remote_accounts
  end

  defp organization_following(organization, opts) do
    remote_accounts =
      organization
      |> Fediverse.list_organization_remote_follows()
      |> Enum.map(& &1.remote_account)

    Social.organization_followed_members(organization, opts) ++
      Social.organization_followed_pages(organization, opts) ++ remote_accounts
  end

  defp target(_conn, "remote-" <> id), do: Fediverse.get_remote_account(id)

  defp target(conn, id) do
    with uuid when not is_nil(uuid) <- UUIDv7.cast_or_nil(id) do
      visible_target(conn, Accounts.get_user(uuid) || Organizations.get_organization(uuid))
    end
  end

  defp visible_target(conn, %User{} = user) do
    if Moderation.profile_visible_to?(user, profile_viewer(conn)), do: user
  end

  defp visible_target(conn, %Organization{} = organization) do
    if Organizations.organization_visible_to?(
         organization,
         organization_viewer(conn, organization)
       ),
       do: organization
  end

  defp visible_target(_conn, nil), do: nil

  # The webpages a member has PROVED are their own, which is what the account's
  # Mastodon `fields` are built from. Loaded here rather than in the presenter,
  # so this stays the endpoints that answer with a **single** account: a
  # follower list renders forty of them, and a presenter that fetched for itself
  # would turn that page into forty queries. A member whose links were not
  # loaded renders no fields (`Vutuv.Profiles.VerifiedLinks.of/1`), never a
  # crash and never a query per row.
  defp with_links(%User{} = user), do: Repo.preload(user, VerifiedLinks.preload_spec())
  defp with_links(other), do: other

  defp profile_viewer(%{assigns: %{current_organization: nil, current_user: user}}), do: user
  defp profile_viewer(_conn), do: nil

  # The acting identity, for the engagement figures on a status. Distinct from
  # `profile_viewer/1`, which answers who may *see* a profile: a page identity
  # sees what an anonymous reader sees, but it likes and bookmarks as itself.
  defp viewer(conn), do: conn.assigns.current_organization || conn.assigns.current_user

  defp organization_viewer(
         %{assigns: %{current_organization: %Organization{id: id}, current_user: user}},
         %Organization{id: id}
       ),
       do: user

  defp organization_viewer(
         %{assigns: %{current_organization: nil, current_user: user}},
         _organization
       ),
       do: user

  defp organization_viewer(_conn, _organization), do: nil

  defp action_error(conn, :not_following),
    do: conn |> put_status(422) |> json(%{error: "The account is not followed"})

  defp action_error(conn, :unsupported),
    do: conn |> put_status(422) |> json(%{error: "This identity cannot perform that action"})

  defp action_error(conn, _reason),
    do: conn |> put_status(422) |> json(%{error: "The relationship could not be changed"})

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "Record not found"})

  # Accounts and statuses from another network are rendered with a prefixed id
  # (`remote-<uuid>`); the uuid underneath is what carries the ordering, so it
  # is what a page boundary compares and advertises.
  # Shared with the timelines rather than kept as a second list: an account's
  # own statuses carry the reshare ids the merged feed mints (`repost-<uuid>`,
  # `remote_repost-<uuid>`), which this copy did not know about and would have
  # handed to the paginator whole.
  defp bare_id(id), do: Pagination.bare_id(id)
end
