defmodule Vutuv.Maps do
  @moduledoc """
  The viewer's map preference: which map service an address on a profile
  links to (the whole address is the link, `address_link/2`), or none at all.

  The preference is the *viewer's*, not the address owner's: when you look at
  someone's profile you see their addresses through your own choice, stored as
  `default_map_service` on `Vutuv.Accounts.User` (`"google"`,
  `"openstreetmap"`, `"apple"` or `"none"`). A logged-out visitor, or any
  member who never touched the setting (a `nil` field), gets the
  **installation default** from `Vutuv.Prefs` (admin-set at
  /admin/preferences); the shipped default is Google Maps.

  This module owns the service labels and the resolution; which values exist
  is the `:default_map_service` pref's `values`. The deep-link URLs themselves
  come from `Vutuv.Address.map_links/1`.
  """

  alias Vutuv.Prefs
  alias Vutuv.Profiles.Address

  @doc "The human label for a service."
  def label(:google), do: "Google Maps"
  def label(:openstreetmap), do: "OpenStreetMap"
  def label(:apple), do: "Apple Maps"

  @doc """
  The viewer's map service, or `nil` when they (or, for an untouched member or
  a logged-out visitor, the installation) chose no map link. The stored string
  is mapped explicitly, never with `String.to_atom/1`.
  """
  def default_service(viewer) do
    case Prefs.get(viewer, :default_map_service) do
      "google" -> :google
      "openstreetmap" -> :openstreetmap
      "apple" -> :apple
      _none -> nil
    end
  end

  @doc """
  The map link for an address as the viewer should see it,
  `%{service: atom, label: binary, url: binary}` for their map service, or
  `nil` when the viewer chose no map link or the address names no city
  (`Vutuv.Address.city?/1`).
  """
  def address_link(%Address{} = address, viewer) do
    default = default_service(viewer)

    if default && Vutuv.Address.city?(address) do
      link(default, Vutuv.Address.map_links(address))
    end
  end

  defp link(service, urls) do
    %{service: service, label: label(service), url: Keyword.fetch!(urls, service)}
  end
end
