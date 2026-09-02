defmodule VutuvWeb.MastodonApi.AccountIds do
  @moduledoc """
  Turning an account id a client sent into the account it names, and deciding
  whether this installation will speak about it at all.

  The id twin of `VutuvWeb.MastodonApi.Handles`, and the same shape as
  `VutuvWeb.MastodonApi.Statuses`: resolving and gating are one call, because an
  id is not a secret. It travels in every timeline, follower list and status the
  caller ever fetched, and it keeps working after the account is frozen,
  suspended or deactivated — so a caller that resolves first and remembers to
  gate second is a caller that will one day forget.

  One did. `AccountController` gated `show`, `statuses`, `following` and the
  relationship actions through its own private `target/2`, while the follower
  list lives in `ListController` and resolved the same parameter with a bare
  `Accounts.get_user/1` — so a withheld member's roster was served in full, and
  its non-emptiness confirmed the account still existed where the profile page
  answers 403.

  `visible_to_identity/2` is the gate itself, and `Handles` reads it from here
  rather than keeping a second copy: "may this identity see this account" is one
  question whether the client spelled the account as an id or as a handle.
  """

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.UUIDv7

  @doc """
  The member, page or remote account `id` names, or `nil` when this
  installation withholds it — which every caller answers as a 404, the
  adapter's documented "same answer for missing and hidden".

  A `remote-`-prefixed id is another server's account, cached here; nothing
  about our own moderation state applies to it.
  """
  def visible(_conn, "remote-" <> id), do: Fediverse.get_remote_account(id)

  def visible(conn, id) do
    with uuid when not is_nil(uuid) <- UUIDv7.cast_or_nil(id) do
      visible_to_identity(Accounts.get_user(uuid) || Organizations.get_organization(uuid), conn)
    end
  end

  @doc """
  Whether the reading identity may see `account`, or `nil` if not.

  Shared with `VutuvWeb.MastodonApi.Handles`, which asks the same question of an
  account it found by handle.
  """
  def visible_to_identity(%User{} = user, conn) do
    if Moderation.profile_visible_to?(user, viewer(conn)), do: user
  end

  # A member viewer gets the **account** rule, the one `GET /api/v1/accounts/:id`
  # answers by (`Organizations.organization_visible_to?/2`, which also covers a
  # manager and a site admin). Anything narrower means an owner can fetch their
  # own frozen page by id and is told "no such account" when they look the same
  # page up by handle. A client acting **as** a page has no member to ask about,
  # so it sees the public pages and itself.
  def visible_to_identity(%Organization{} = organization, conn) do
    if Organizations.organization_visible_to?(
         organization,
         organization_viewer(conn, organization)
       ),
       do: organization
  end

  def visible_to_identity(nil, _conn), do: nil

  @doc """
  Who is reading, for the purpose of deciding what may be seen.

  A member reads as themselves; an identity acting for a page reads as an
  anonymous visitor, because a page has no standing to see a withheld profile.
  Distinct from the acting identity a like or a bookmark is recorded under,
  which is `VutuvWeb.MastodonApi.Statuses.viewer/1`.
  """
  def viewer(%{assigns: %{current_organization: nil, current_user: user}}), do: user
  def viewer(_conn), do: nil

  @doc """
  Who is reading, when the subject is a page: its own team reads as the member
  behind the identity, everyone else as themselves.
  """
  def organization_viewer(
        %{assigns: %{current_organization: %Organization{id: id}, current_user: user}},
        %Organization{id: id}
      ),
      do: user

  def organization_viewer(
        %{assigns: %{current_organization: nil, current_user: user}},
        _organization
      ),
      do: user

  def organization_viewer(_conn, _organization), do: nil
end
