defmodule VutuvWeb.OrganizationLive.ManageGate do
  @moduledoc """
  Re-asks, on the socket, the permission `OrganizationController.manage/4` asked
  of the request.

  That controller is the only gate these pages had. It checks the page's own
  predicate and then hands the LiveView an `organization_id` inside a
  `live_render` session — signed, **not** encrypted, bound to no user and valid
  for days. A role taken away afterwards therefore did not reach an open tab,
  and a reconnect (every deploy causes one, and the tokens sit in the page
  source of any render the holder could once load) re-mounted with the same map.
  `Vutuv.Organizations.set_roles/4` names this attack in its own docstring; only
  `Roles` and `Apps` were re-checking.

  The predicate is the caller's, because each page has its own — the same
  function the controller passes, so the two cannot drift into disagreeing about
  who may open a page and who may keep it open.

  Refusing navigates to the organization's public page rather than raising: a
  member who has lost a role can still see the page, and a raise would put the
  socket into a crash-retry loop under whoever is holding the tab open.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  alias Phoenix.LiveView
  alias Vutuv.Organizations

  @doc """
  `{:ok, organization}` when the socket's viewer still satisfies `can?`, or
  `{:refused, socket}` carrying the navigation away.

  Call it after `VutuvWeb.Live.InitAssigns.assign_embedded/2`, which is what
  resolves the viewer from the session token — the id in the curated map is not
  an identity and must not be read as one (issue #1036).
  """
  def allow(socket, session, can?) when is_function(can?, 2) do
    organization = Organizations.get_organization!(session["organization_id"])

    if can?.(organization, socket.assigns.current_user) do
      {:ok, organization}
    else
      {:refused, LiveView.push_navigate(socket, to: ~p"/organizations/#{organization}")}
    end
  end
end
