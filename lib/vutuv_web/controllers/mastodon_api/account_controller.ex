defmodule VutuvWeb.MastodonApi.AccountController do
  @moduledoc "The authenticated account identity expected after OAuth login."

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Pagination

  def verify_credentials(conn, _params) do
    subject = conn.assigns.current_organization || conn.assigns.current_user

    account =
      subject
      |> Presenter.account()
      |> Map.put(:following_count, following_count(subject))

    json(conn, account)
  end

  def show(conn, %{"id" => id}) do
    case target(conn, id) do
      nil -> not_found(conn)
      account -> json(conn, Presenter.account(account))
    end
  end

  def follow(conn, %{"id" => id}), do: relationship_action(conn, id, :follow)
  def unfollow(conn, %{"id" => id}), do: relationship_action(conn, id, :unfollow)
  def mute(conn, %{"id" => id}), do: relationship_action(conn, id, :mute)
  def unmute(conn, %{"id" => id}), do: relationship_action(conn, id, :unmute)
  def block(conn, %{"id" => id}), do: relationship_action(conn, id, :block)
  def unblock(conn, %{"id" => id}), do: relationship_action(conn, id, :unblock)

  def relationships(conn, params) do
    ids = List.wrap(params["id"] || params["id[]"])

    relationships =
      ids
      |> Enum.map(&target(conn, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&relationship(conn, &1))

    json(conn, relationships)
  end

  def statuses(conn, %{"id" => id} = params) do
    page = Pagination.params(params)
    fetch = Pagination.fetch_size(page)

    statuses =
      case target(conn, id) do
        %User{} = user ->
          user
          |> Posts.profile_posts(profile_viewer(conn), limit: fetch)
          |> Enum.map(&Presenter.status_from_entry/1)

        %Organization{} = organization ->
          organization
          |> Posts.organization_posts_page(organization_viewer(conn, organization), limit: fetch)
          |> Map.fetch!(:entries)
          |> Enum.map(&Presenter.status/1)

        %RemoteAccount{} = account ->
          subject = conn.assigns.current_organization || conn.assigns.current_user
          {posts, _more?} = Fediverse.account_posts(account, subject)

          posts
          |> Enum.take(fetch)
          |> Enum.map(fn post -> Presenter.status(%{post | remote_account: account}) end)

        _missing_or_unsupported ->
          []
      end
      |> Pagination.window(page, &bare_id(&1.id))

    conn
    |> Pagination.link_header(Enum.map(statuses, &bare_id(&1.id)), page)
    |> json(statuses)
  end

  def following(conn, %{"id" => id} = params) do
    page = Pagination.params(params)

    accounts =
      case {target(conn, id), conn.assigns.current_organization} do
        {%User{} = user, _identity} ->
          user_following(conn, user)

        {%Organization{id: organization_id} = organization, %Organization{id: organization_id}} ->
          organization_following(organization)

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
        case Fediverse.organization_remote_follow_for(organization, target) do
          nil -> :ok
          follow -> Fediverse.unfollow_remote_as_organization(organization, follow.id)
        end
    end
  end

  defp apply_action(conn, target, action) when action in [:mute, :unmute] do
    muted? = action == :mute

    case {conn.assigns.current_organization, target} do
      {nil, %RemoteAccount{id: id}} ->
        Fediverse.set_remote_follow_mute(conn.assigns.current_user, id, muted?)

      {%Organization{} = organization, %RemoteAccount{id: id}} ->
        Fediverse.set_organization_remote_follow_mute(organization, id, muted?)

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
      organization -> not is_nil(Fediverse.organization_remote_follow_for(organization, target))
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
        organization -> Fediverse.organization_remote_follow_for(organization, target)
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
        organization -> Fediverse.organization_remote_follow_for(organization, target)
      end

    match?(%{state: "requested"}, follow)
  end

  defp requested?(_conn, _target), do: false

  defp user_following(conn, user) do
    local_members = Social.follows_page(user, :followees, %{}).users
    local_organizations = user |> Social.followed_organizations() |> Enum.map(&elem(&1, 1))

    remote_accounts =
      if is_nil(conn.assigns.current_organization) and conn.assigns.current_user.id == user.id,
        do: user |> Fediverse.list_remote_follows() |> Enum.map(& &1.remote_account),
        else: []

    local_members ++ local_organizations ++ remote_accounts
  end

  defp organization_following(organization) do
    local_accounts =
      organization
      |> Social.organization_followees()
      |> Enum.map(&elem(&1, 1))

    remote_accounts =
      organization
      |> Fediverse.list_organization_remote_follows()
      |> Enum.map(& &1.remote_account)

    local_accounts ++ remote_accounts
  end

  defp following_count(%User{} = user),
    do: Social.followee_count(user) + Fediverse.remote_follow_count(user)

  defp following_count(%Organization{} = organization) do
    Social.organization_followee_count(organization) +
      length(Fediverse.list_organization_remote_follows(organization))
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

  defp profile_viewer(%{assigns: %{current_organization: nil, current_user: user}}), do: user
  defp profile_viewer(_conn), do: nil

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
  defp bare_id("remote-note-author-" <> rest), do: rest
  defp bare_id("remote-note-" <> rest), do: rest
  defp bare_id("remote-" <> rest), do: rest
  defp bare_id(id), do: id
end
