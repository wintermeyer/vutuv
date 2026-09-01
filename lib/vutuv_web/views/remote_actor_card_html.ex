defmodule VutuvWeb.RemoteActorCardHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.FediverseComponents
  import VutuvWeb.PostComponents

  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteFollow

  embed_templates("../templates/remote_actor_card/*")

  @doc """
  What the card calls the account: its display name, else the address it wears
  out there, else the address the reader tapped.

  Deliberately not `RemoteAccount.label/1`, whose last resort is the bare
  `actor_uri` — a card headed by a URL says nothing a reader was not already
  looking at, and the address they clicked says more.
  """
  def card_name(nil, address), do: "@" <> address

  def card_name(%RemoteAccount{} = account, address),
    do:
      RemoteAccount.display_name(account) || RemoteAccount.display_handle(account) ||
        card_name(nil, address)

  @doc "The `@user@host` line under the name, from the row where we have one."
  def card_handle(nil, address), do: "@" <> address

  def card_handle(%RemoteAccount{} = account, address),
    do: RemoteAccount.display_handle(account) || card_handle(nil, address)

  @doc """
  The monogram, from the same source every other remote-account surface uses
  (`remote_initials/1`) so one account is not "T" on its page and "@" here — the
  account's label starts with the `@` of its address whenever it has no display
  name, and `name_initials/1` would take that as the initial.

  For an address that resolved to nobody there is no row, so the handle the
  reader typed is all there is.
  """
  def card_initials(nil, address),
    do: address |> String.split("@") |> List.first() |> name_initials()

  def card_initials(%RemoteAccount{} = account, _address), do: remote_initials(account)

  @doc """
  Where "View the original" goes: the canonical actor id once we hold the row,
  and otherwise the same `https://host/@user` the mention's own `href` carries
  (`Vutuv.Fediverse.Handle.web_profile_url/2` owns that spelling), so the card
  can never send a reader somewhere the link would not have.
  """
  def origin_url(%RemoteAccount{actor_uri: uri}, _address), do: uri

  def origin_url(nil, address) do
    case RemoteFollow.parse_address(address) do
      {:ok, {user, host}} -> Handle.web_profile_url(user, host)
      _unparsable -> nil
    end
  end
end
