defmodule Vutuv.MastodonApi.Access do
  @moduledoc """
  Resolves the identity behind a Mastodon token and re-checks its powers.

  A token always belongs to the signed-in member for audit and revocation. An
  optional organization is the identity it reads and speaks as. Organization
  powers are deliberately derived from live roles on every request, so removing
  a role takes effect without waiting for token expiry or another login.

  **The organization side is exactly the `publisher` role and nothing else.**
  This adapter deliberately adds no role of its own: a Mastodon client is a
  second channel onto the powers the Redaktion already has in the browser
  (posting as the page, reading its feed, curating its follows), never a new
  power and never a new grant. Splitting reading from curating — so that a
  whole workforce can consume a page's feed without also being able to speak
  in its name — is worth doing and is written up under "Team roles" in
  `docs/architecture/organizations.md`; it needs its own change, because the
  interesting parts of it are a `/feed` tab and a domain rule, not a scope
  table. Until then the three scope families below share one predicate on
  purpose, which is why they run through `acts_for?/2` rather than three
  lookalike checks that could quietly drift apart.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.ApiAuth.Token
  alias Vutuv.MastodonApi.Scopes
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.UUIDv7

  def identities(%User{} = user, requested_scopes) do
    personal =
      if user.mastodon_clients? do
        [%{value: "person", subject: user, scopes: requested_scopes}]
      else
        []
      end

    organizations =
      user
      |> Organizations.member_organizations()
      # `member_organizations/1` already returns each page's roles, so the
      # acting answer is in hand: asking for it again cost one role-table read
      # per scope plus one more per page (a member of three pages picking from
      # eight scopes paid twenty-seven), all of them re-reading rows this list
      # was built from.
      |> Enum.flat_map(fn {organization, roles} ->
        acting? = "publisher" in roles
        scopes = scopes_for(requested_scopes, organization, acting?)

        if organization.mastodon_clients? and acting? and scopes != [] do
          [%{value: "organization:" <> organization.id, subject: organization, scopes: scopes}]
        else
          []
        end
      end)

    personal ++ organizations
  end

  def select(%User{} = user, "person", scopes) do
    if user.mastodon_clients?, do: {:ok, nil, scopes}, else: {:error, :access_disabled}
  end

  def select(%User{} = user, "organization:" <> id, scopes) do
    organization =
      case UUIDv7.cast_or_nil(id) do
        nil -> nil
        uuid -> Organizations.get_organization(uuid)
      end

    case organization do
      %Organization{} = organization ->
        allowed = allowed_scopes(user, organization, scopes)

        if organization.mastodon_clients? and acts_for?(organization, user) and allowed != [],
          do: {:ok, organization, allowed},
          else: {:error, :forbidden}

      nil ->
        {:error, :forbidden}
    end
  end

  def select(%User{} = user, nil, scopes), do: select(user, "person", scopes)
  def select(_user, _identity, _scopes), do: {:error, :forbidden}

  def authorize_token(%Token{organization: nil}, %User{mastodon_clients?: true}), do: {:ok, nil}

  def authorize_token(%Token{organization: %Organization{} = organization}, %User{} = user) do
    if organization.mastodon_clients? and acts_for?(organization, user),
      do: {:ok, organization},
      else: {:error, :access_disabled}
  end

  def authorize_token(_token, _user), do: {:error, :access_disabled}

  @doc """
  Whether `user` may act as `organization` through a client — the `publisher`
  role, the same one `Organizations.acting_organization/2` asks for the
  browser's identity switch. `nil` is the member's own identity, which they may
  always act as (their `mastodon_clients?` switch is checked separately, since
  that is a kill switch rather than a permission).
  """
  def acts_for?(nil, %User{}), do: true

  def acts_for?(%Organization{} = organization, %User{} = user),
    do: Organizations.publisher?(organization, user)

  @doc """
  The subset of `requested_scopes` this identity may actually hold, which is
  what the consent screen offers and what the token is minted with. The plug
  re-runs it per request, so a withdrawn role narrows an existing token rather
  than waiting for it to expire.
  """
  def allowed_scopes(user, organization, requested_scopes),
    do: scopes_for(requested_scopes, organization, acts_for?(organization, user))

  # The acting answer is a read of the role table, and it does not change
  # between the scopes of one request — so it is taken once for the whole list
  # rather than once per scope inside the filter.
  defp scopes_for(requested_scopes, organization, acting?) do
    Enum.filter(requested_scopes, fn scope ->
      scope in Scopes.all() and permitted?(scope, organization, acting?)
    end)
  end

  # Blocking is the one scope a page can never hold. A block is a member's own
  # safety tool and it cuts both ways between two people; a page blocking on
  # behalf of whoever happens to hold a role today is not the same act, and the
  # relationship it would write has no member on one side. The account
  # controller refuses it a second time, so this is the outer of two gates.
  defp permitted?("write:blocks", organization, _acting?), do: is_nil(organization)
  defp permitted?(_scope, _organization, acting?), do: acting?
end
