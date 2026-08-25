defmodule VutuvWeb.MastodonApi.Handles do
  @moduledoc """
  Turning a handle a client sent into the account it names.

  One owner for the whole grammar, because two endpoints ask the same question
  and would otherwise answer it differently: `GET /api/v2/search?resolve=true`
  and `GET /api/v1/accounts/lookup`. They differ in exactly one thing — whether
  a handle we have never seen may cost a WebFinger request — so that is the one
  thing this module splits (`resolve/2` may, `local/2` never does).

  Members and organization pages share one handle namespace here, so `@acme`
  names one of the two and never both; a page is also reachable by its slug,
  which is the address its canonical URL carries.
  """

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.MastodonApi
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias VutuvWeb.MastodonApi.Statuses

  @doc """
  The account `query` names, resolving an unknown `@user@host` over the network.

  This is the search page's "resolve" behaviour, and the network call is the
  reason it is not the default anywhere else — nor, within this function, the
  default for every query that merely *contains* an `@`. Reaching out costs one
  of the member's thirty hourly remote-follow slots before the request is even
  made (`Fediverse.resolve_remote_account/2` claims the budget first), and
  search asks this on **every** query, so an address-shaped one that the member
  did not write as a handle — a pasted email, a login name — is answered from
  here alone. The leading `@` is what says "this is a handle, go and find it".
  """
  def resolve(conn, "@" <> address), do: parse(conn, address, true)
  def resolve(conn, query), do: parse(conn, query, false)

  @doc """
  The account `query` names **without** ever leaving this installation.

  Mastodon's own `/api/v1/accounts/lookup` is defined as the WebFinger-free
  twin of search, and a client leans on it: it is what the compose window calls
  on every `@` it sees, so a version that reached out would spend somebody's
  hourly follow budget on typing. A handle on a host that is not ours therefore
  answers nothing here rather than being fetched.
  """
  def local(conn, "@" <> address), do: parse(conn, address, false)
  def local(conn, query), do: parse(conn, query, false)

  defp parse(conn, address, remote?) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [handle] -> local_account(conn, handle)
      [handle, host] -> qualified(conn, address, handle, String.downcase(host), remote?)
    end
  end

  defp parse(_conn, _query, _remote?), do: nil

  # `client_host?/1`, not a list of the two hosts we happen to think of: it also
  # answers for the `www.` alias, and serving a site at both the apex and its
  # `www.` name is the oldest convention on the web. Spelled out, the miss was
  # not a polite "unknown handle" — `@member@www.<our host>` fell through to the
  # remote branch, so this installation WebFingered **itself** over the network
  # and told the member their own site was unreachable.
  defp qualified(conn, address, handle, host, remote?) do
    cond do
      MastodonApi.client_host?(host) -> local_account(conn, handle)
      remote? -> remote_account(conn, address)
      true -> nil
    end
  end

  defp remote_account(conn, address) do
    subject = Statuses.viewer(conn)

    case Fediverse.resolve_remote_account(subject, "@" <> address) do
      {:ok, account} -> account
      _error -> nil
    end
  end

  defp local_account(conn, handle) do
    handle
    |> String.downcase()
    |> known_account()
    |> visible_to_identity(conn)
  end

  defp known_account(handle) do
    Accounts.get_user_by_username(handle) ||
      Organizations.get_organization_by_username(handle) ||
      Organizations.get_organization_by_slug(handle)
  end

  defp visible_to_identity(%User{} = user, conn) do
    viewer = if is_nil(conn.assigns.current_organization), do: conn.assigns.current_user
    if Moderation.profile_visible_to?(user, viewer), do: user
  end

  # A member viewer gets the **account** rule, the one `GET /api/v1/accounts/:id`
  # answers by (`Organizations.organization_visible_to?/2`, which also covers a
  # manager and a site admin). Anything narrower means an owner can fetch their
  # own frozen page by id and is told "no such account" when they look the same
  # page up by handle. A client acting **as** a page has no member to ask about,
  # so it sees the public pages and itself.
  defp visible_to_identity(%Organization{} = organization, conn) do
    case conn.assigns.current_organization do
      %Organization{id: id} ->
        if Organizations.public_visible?(organization) or id == organization.id,
          do: organization

      nil ->
        if Organizations.organization_visible_to?(organization, conn.assigns.current_user),
          do: organization
    end
  end

  defp visible_to_identity(nil, _conn), do: nil
end
