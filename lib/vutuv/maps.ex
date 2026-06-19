defmodule Vutuv.Maps do
  @moduledoc """
  The viewer's map preferences: which map services to surface on the addresses
  a logged-in member looks at, and which one is their default (rendered as the
  primary "Open in …" button on the profile address card).

  The preference is the *viewer's*, not the address owner's: when you look at
  someone's profile you see their addresses through your own map choices,
  stored on `Vutuv.Accounts.User` (`map_google?` / `map_openstreetmap?` /
  `map_apple?` and `default_map_service`). A logged-out visitor (or any member
  who never touched the setting) gets the canonical default: all three services
  on, Google the default — exactly the behaviour before the feature.

  This module is the single source of truth for the canonical service list,
  their labels and the resolution rules, and it never trusts the stored fields
  to be mutually consistent (a default pointing at a disabled service falls back
  to the first enabled one). The deep-link URLs themselves come from
  `Vutuv.Address.map_links/1`.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Address

  # Canonical order. The head is the default-of-defaults (Google), and the order
  # is the order alternatives render in.
  @services [:google, :openstreetmap, :apple]
  @service_strings Enum.map(@services, &Atom.to_string/1)

  @doc "The canonical map services, in display order."
  def services, do: @services

  @doc "The canonical map services as their stored string forms."
  def service_strings, do: @service_strings

  @doc "Whether `service` (a string) names a known map service."
  def valid_service?(service) when is_binary(service), do: service in @service_strings
  def valid_service?(_), do: false

  @doc "The human label for a service."
  def label(:google), do: "Google Maps"
  def label(:openstreetmap), do: "OpenStreetMap"
  def label(:apple), do: "Apple Maps"

  @doc """
  The viewer's enabled services, in canonical order. A `nil` viewer (logged out)
  or a legacy row with `nil` flags reads as "all on".
  """
  def enabled_services(viewer), do: Enum.filter(@services, &enabled?(viewer, &1))

  defp enabled?(nil, _service), do: true
  defp enabled?(%User{map_google?: flag}, :google), do: on?(flag)
  defp enabled?(%User{map_openstreetmap?: flag}, :openstreetmap), do: on?(flag)
  defp enabled?(%User{map_apple?: flag}, :apple), do: on?(flag)

  defp on?(nil), do: true
  defp on?(flag) when is_boolean(flag), do: flag

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

  # The stored preference, mapped explicitly (never String.to_atom on a column).
  defp preferred_default(%User{default_map_service: "openstreetmap"}), do: :openstreetmap
  defp preferred_default(%User{default_map_service: "apple"}), do: :apple
  defp preferred_default(_viewer), do: :google

  @doc """
  The map links for an address as the viewer should see them:

      %{primary: link | nil, alternatives: [link]}

  where each `link` is `%{service: atom, label: binary, url: binary}`. The
  `primary` is the viewer's default service (the "Open in …" button) and
  `alternatives` are the rest of their enabled services in canonical order.
  Both are `nil`/`[]` when the viewer has disabled every service.
  """
  def address_links(%Address{} = address, viewer) do
    case default_service(viewer) do
      nil ->
        %{primary: nil, alternatives: []}

      default ->
        urls = Vutuv.Address.map_links(address)

        alternatives =
          enabled_services(viewer)
          |> Enum.reject(&(&1 == default))
          |> Enum.map(&link(&1, urls))

        %{primary: link(default, urls), alternatives: alternatives}
    end
  end

  defp link(service, urls) do
    %{service: service, label: label(service), url: Keyword.fetch!(urls, service)}
  end
end
