defmodule VutuvWeb.OrganizationController do
  @moduledoc """
  Verified organization pages (issue #929). The HTML directory (`/organizations`) and
  page (`/organizations/:slug`) are the LiveViews `VutuvWeb.OrganizationLive.Index` /
  `Show`, `live_render`ed here so the controller stays the entry point and can
  negotiate the **agent-format siblings** (`.md/.txt/.json/.xml`,
  `VutuvWeb.AgentDocs.OrganizationDoc`) — the profile / newsfeed pattern. The claim
  wizard (`/organizations/new`) and the owner edit form (`/organizations/:slug/edit`)
  are the `New` / `Edit` LiveViews, gated on login / ownership here.

  Only an active, non-frozen, `geo?` organization serves agent formats; every other
  state 404s them (a `.md` URL must never serve HTML), exactly like a hidden
  profile.
  """

  use VutuvWeb, :controller

  import Phoenix.LiveView.Controller, only: [live_render: 3]

  alias Vutuv.Organizations
  alias Vutuv.Pages
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.OrganizationDoc
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    case AgentDocs.negotiate(conn) do
      :html ->
        session =
          base_session(conn)
          |> Map.put("q", conn.params["q"])
          |> Map.put("page", conn.params["page"])

        conn
        |> AgentDocs.put_html_alternates()
        |> put_layout(html: false)
        |> live_render(VutuvWeb.OrganizationLive.Index, session: session)

      format ->
        # Honor ?page= and ?q= like the HTML branch, so agent/crawler consumers
        # can page past the first 24 and filter (llms.txt promises ?page=N).
        page =
          Organizations.directory_page(
            page: Pages.page_param(conn.params),
            search: conn.params["q"]
          )

        AgentDocs.send_doc(conn, format, OrganizationDoc.build_index(page.entries, page.total))
    end
  end

  def show(conn, %{"slug" => slug}) do
    case Organizations.fetch_visible_organization(slug, conn.assigns[:current_user]) do
      {:error, :not_found} ->
        ControllerHelpers.render_error(conn, 404)

      {:ok, organization} ->
        render_page(conn, organization)
    end
  end

  @doc """
  Renders an already-resolved, viewer-visible organization page — the HTML LiveView
  or an agent-format doc, per negotiation. Reused by the root-handle dispatcher
  (issue #941, `VutuvWeb.Plug.UserResolveSlug`) so `/:handle` and
  `/organizations/:slug` serve the identical page.
  """
  def render_page(conn, organization) do
    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> put_organization_canonical(organization)
        |> AgentDocs.put_html_alternates()
        |> put_layout(html: false)
        |> live_render(VutuvWeb.OrganizationLive.Show,
          session: Map.put(base_session(conn), "organization_id", organization.id)
        )

      format ->
        send_organization_doc(conn, format, organization)
    end
  end

  # When the organization has claimed a root handle (issue #941) the canonical URL is
  # the root `/:handle`, whether the page was reached at `/organizations/:slug` or at
  # `/:handle`. A handle-less organization falls through to the request-path default
  # (its `/organizations/:slug`).
  defp put_organization_canonical(conn, %{username: username}) when is_binary(username),
    do: assign(conn, :canonical_url, VutuvWeb.Endpoint.url() <> "/" <> username)

  defp put_organization_canonical(conn, _organization), do: conn

  def new(conn, _params) do
    case conn.assigns[:current_user] do
      %{email_confirmed?: true} ->
        conn
        |> put_layout(html: false)
        |> live_render(VutuvWeb.OrganizationLive.New, session: base_session(conn))

      %{} ->
        conn
        |> put_flash(
          :error,
          gettext("Please confirm your email address before claiming an organization page.")
        )
        |> redirect(to: ~p"/organizations")

      nil ->
        conn
        |> put_flash(:error, gettext("Please log in to claim an organization page."))
        |> redirect(to: ~p"/login")
    end
  end

  def edit(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Edit, &Organizations.can_edit_page?/2)

  def roles(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Roles, &Organizations.can_manage_roles?/2)

  def domains(conn, %{"slug" => slug}),
    do:
      manage(conn, slug, VutuvWeb.OrganizationLive.Domains, &Organizations.can_manage_domains?/2)

  def exclusions(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Exclusions, &Organizations.can_manage?/2)

  # Shared gate for the owner/admin management pages: log-in required, then the
  # per-page permission (`can?`); otherwise a 404 (never reveal the page exists).
  defp manage(conn, slug, live_view, can?) do
    viewer = conn.assigns[:current_user]
    organization = viewer && Organizations.get_organization_by_slug(slug)

    cond do
      is_nil(viewer) ->
        conn
        |> put_flash(:error, gettext("Please log in first."))
        |> redirect(to: ~p"/login")

      organization && can?.(organization, viewer) ->
        conn
        |> put_layout(html: false)
        |> live_render(live_view,
          session: Map.put(base_session(conn), "organization_id", organization.id)
        )

      true ->
        ControllerHelpers.render_error(conn, 404)
    end
  end

  # The agent formats render the anonymous public view, so they 404 for any
  # page that is not active + geo? (pending / frozen / archived / geo? off) no
  # matter who asks — cache-safe, like a hidden profile's siblings.
  defp send_organization_doc(conn, format, organization) do
    if Organizations.agent_visible?(organization) do
      AgentDocs.send_doc(conn, format, OrganizationDoc.build_show(organization))
    else
      ControllerHelpers.render_error(conn, 404)
    end
  end

  defp base_session(conn) do
    %{
      "user_id" => conn.assigns[:current_user_id],
      "locale" => conn.assigns[:locale],
      "request_path" => conn.request_path
    }
  end
end
