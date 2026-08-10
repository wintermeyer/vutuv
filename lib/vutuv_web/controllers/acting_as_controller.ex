defmodule VutuvWeb.ActingAsController do
  @moduledoc """
  Switching into an organization and back out again (issue #1335).

  The session carries only `acting_as_organization_id`, and it is a hint rather
  than a credential: `VutuvWeb.Plug.ActingAs` re-asks `organization_roles` on
  every request and `VutuvWeb.Live.InitAssigns` on every socket mount, so what
  is written here can never by itself grant anything.

  It is a **session** value with no expiry of its own, which is exactly the
  "the switch does not outlive the session" rule: come back tomorrow with a new
  session and you are yourself again. Both directions are POST/DELETE with CSRF
  — a `GET` that changes who you are speaking as would fire on a link prefetch.
  """

  use VutuvWeb, :controller

  alias Vutuv.AccountEvents
  alias Vutuv.Organizations
  alias VutuvWeb.ControllerHelpers

  def create(conn, %{"slug" => slug}) do
    user = conn.assigns[:current_user]
    organization = user && Organizations.get_organization_by_slug(slug)

    # The same predicate the plug will apply on the next request, asked here so
    # a member without the role never gets a mode that immediately evaporates.
    if organization && Organizations.acting_organization(user, organization.id) do
      AccountEvents.record(user, "acted_as_organization",
        conn: conn,
        details: %{"organization" => organization.name, "organization_slug" => organization.slug}
      )

      conn
      |> put_session(:acting_as_organization_id, organization.id)
      |> put_flash(
        :info,
        gettext("You are writing as %{name} now.", name: organization.name)
      )
      |> redirect(to: Organizations.canonical_path(organization))
    else
      ControllerHelpers.render_error(conn, 404)
    end
  end

  def delete(conn, _params) do
    user = conn.assigns[:current_user]
    organization = conn.assigns[:acting_as]

    if organization do
      AccountEvents.record(user, "stopped_acting_as_organization",
        conn: conn,
        details: %{"organization" => organization.name, "organization_slug" => organization.slug}
      )
    end

    conn
    |> delete_session(:acting_as_organization_id)
    |> put_flash(:info, gettext("You are yourself again."))
    |> redirect(to: return_to(conn))
  end

  # Back where they were, so leaving the mode is not also a navigation. Only a
  # same-site path is honored: an absolute URL in a parameter is an open
  # redirect, and this one is reachable from every page.
  defp return_to(conn) do
    case conn.params["return_to"] do
      "/" <> _ = path -> if String.starts_with?(path, "//"), do: ~p"/feed", else: path
      _ -> ~p"/feed"
    end
  end
end
