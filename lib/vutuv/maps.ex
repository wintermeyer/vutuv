defmodule Vutuv.Maps do
  @moduledoc """
  The viewer's map preferences: which map service an address on a profile
  links to (the whole address is the link, `address_link/2`), or none at all.

  The preference is the *viewer's*, not the address owner's: when you look at
  someone's profile you see their addresses through your own map choices,
  stored on `Vutuv.Accounts.User` (`map_google?` / `map_openstreetmap?` /
  `map_apple?` and `default_map_service`). A logged-out visitor (or any member
  who never touched the setting — a `nil` field) gets the **installation
  default** from `Vutuv.Prefs` (admin-set at /admin/preferences); the shipped
  default is Google Maps.

  This module is the single source of truth for the canonical service list,
  their labels and the resolution rules, and it never trusts the stored fields
  to be mutually consistent (a default pointing at a disabled service falls back
  to the first enabled one). The deep-link URLs themselves come from
  `Vutuv.Address.map_links/1`.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs
  alias Vutuv.Profiles.Address

  # Canonical order. The head is the default-of-defaults (Google), and the order
  # is the one the settings select and the fallback for a disabled default use.
  @services [:google, :openstreetmap, :apple]
  @service_strings Enum.map(@services, &Atom.to_string/1)

  @doc "The canonical map services, in display order."
  def services, do: @services

  @doc "The human label for a service."
  def label(:google), do: "Google Maps"
  def label(:openstreetmap), do: "OpenStreetMap"
  def label(:apple), do: "Apple Maps"

  @doc """
  The viewer's enabled services, in canonical order. A `nil` viewer (logged
  out) or a `nil` flag resolves to the installation default.
  """
  def enabled_services(viewer), do: Enum.filter(@services, &enabled?(viewer, &1))

  defp enabled?(nil, service), do: Prefs.default(flag_key(service))
  defp enabled?(%User{map_google?: flag}, :google), do: on?(flag, :google)
  defp enabled?(%User{map_openstreetmap?: flag}, :openstreetmap), do: on?(flag, :openstreetmap)
  defp enabled?(%User{map_apple?: flag}, :apple), do: on?(flag, :apple)

  defp on?(nil, service), do: Prefs.default(flag_key(service))
  defp on?(flag, _service) when is_boolean(flag), do: flag

  defp flag_key(:google), do: :map_google?
  defp flag_key(:openstreetmap), do: :map_openstreetmap?
  defp flag_key(:apple), do: :map_apple?

  @doc """
  The viewer's effective default service, resolved to one that is actually
  enabled, or `nil` when the viewer has turned every service off.
  """
  def default_service(viewer) do
    enabled = enabled_services(viewer)
    preferred = preferred_default(viewer)

    cond do
      enabled == [] -> nil
      preferred in enabled -> preferred
      true -> hd(enabled)
    end
  end

  # The stored preference, mapped explicitly (never String.to_atom on a
  # column); an unset one falls back to the installation default.
  defp preferred_default(%User{default_map_service: "google"}), do: :google
  defp preferred_default(%User{default_map_service: "openstreetmap"}), do: :openstreetmap
  defp preferred_default(%User{default_map_service: "apple"}), do: :apple
  defp preferred_default(_viewer), do: service_atom(Prefs.default(:default_map_service))

  defp service_atom("openstreetmap"), do: :openstreetmap
  defp service_atom("apple"), do: :apple
  defp service_atom(_), do: :google

  @doc """
  The map link for an address as the viewer should see it,
  `%{service: atom, label: binary, url: binary}` for their default service, or
  `nil` when the viewer has disabled every service or the address names no
  city (`Vutuv.Address.city?/1`).
  """
  def address_link(%Address{} = address, viewer) do
    default = default_service(viewer)

    if default && Vutuv.Address.city?(address) do
      link(default, Vutuv.Address.map_links(address))
    end
  end

  @doc """
  The viewer's settings choice: their effective service as a string, or
  `"none"` when they have turned every service off.
  """
  def choice(viewer) do
    case default_service(viewer) do
      nil -> "none"
      service -> Atom.to_string(service)
    end
  end

  @doc """
  The user attrs behind the settings choice `choice`, the service addresses
  open in or `"none"`. `"none"` switches every service off; a service becomes
  the default and is switched on for this member, even where its flag still
  inherits the installation default, so an admin turning it off site-wide
  cannot move somebody who picked it. Anything else goes on as the default
  for the changeset to reject.
  """
  def choice_attrs(%User{}, "none") do
    Map.new(@services, &{Atom.to_string(flag_key(&1)), false})
  end

  def choice_attrs(%User{}, choice) when choice in @service_strings do
    %{"default_map_service" => choice, "map_#{choice}?" => true}
  end

  def choice_attrs(%User{}, choice), do: %{"default_map_service" => choice}

  defp link(service, urls) do
    %{service: service, label: label(service), url: Keyword.fetch!(urls, service)}
  end
end
