defmodule VutuvWeb.CompanyController do
  @moduledoc """
  Verified company pages (issue #929). The HTML directory (`/companies`) and
  page (`/companies/:slug`) are the LiveViews `VutuvWeb.CompanyLive.Index` /
  `Show`, `live_render`ed here so the controller stays the entry point and can
  negotiate the **agent-format siblings** (`.md/.txt/.json/.xml`,
  `VutuvWeb.AgentDocs.CompanyDoc`) — the profile / newsfeed pattern. The claim
  wizard (`/companies/new`) and the owner edit form (`/companies/:slug/edit`)
  are the `New` / `Edit` LiveViews, gated on login / ownership here.

  Only an active, non-frozen, `geo?` company serves agent formats; every other
  state 404s them (a `.md` URL must never serve HTML), exactly like a hidden
  profile.
  """

  use VutuvWeb, :controller

  import Phoenix.LiveView.Controller, only: [live_render: 3]

  alias Vutuv.Companies
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.CompanyDoc
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
        |> live_render(VutuvWeb.CompanyLive.Index, session: session)

      format ->
        page = Companies.directory_page()
        AgentDocs.send_doc(conn, format, CompanyDoc.build_index(page.entries, page.total))
    end
  end

  def show(conn, %{"slug" => slug}) do
    case Companies.fetch_visible_company(slug, conn.assigns[:current_user]) do
      {:error, :not_found} ->
        ControllerHelpers.render_error(conn, 404)

      {:ok, company} ->
        render_page(conn, company)
    end
  end

  @doc """
  Renders an already-resolved, viewer-visible company page — the HTML LiveView
  or an agent-format doc, per negotiation. Reused by the root-handle dispatcher
  (issue #941, `VutuvWeb.Plug.UserResolveSlug`) so `/:handle` and
  `/companies/:slug` serve the identical page.
  """
  def render_page(conn, company) do
    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> put_company_canonical(company)
        |> AgentDocs.put_html_alternates()
        |> put_layout(html: false)
        |> live_render(VutuvWeb.CompanyLive.Show,
          session: Map.put(base_session(conn), "company_id", company.id)
        )

      format ->
        send_company_doc(conn, format, company)
    end
  end

  # When the company has claimed a root handle (issue #941) the canonical URL is
  # the root `/:handle`, whether the page was reached at `/companies/:slug` or at
  # `/:handle`. A handle-less company falls through to the request-path default
  # (its `/companies/:slug`).
  defp put_company_canonical(conn, %{username: username}) when is_binary(username),
    do: assign(conn, :canonical_url, VutuvWeb.Endpoint.url() <> "/" <> username)

  defp put_company_canonical(conn, _company), do: conn

  def new(conn, _params) do
    case conn.assigns[:current_user] do
      %{email_confirmed?: true} ->
        conn
        |> put_layout(html: false)
        |> live_render(VutuvWeb.CompanyLive.New, session: base_session(conn))

      %{} ->
        conn
        |> put_flash(
          :error,
          gettext("Please confirm your email address before claiming a company page.")
        )
        |> redirect(to: ~p"/companies")

      nil ->
        conn
        |> put_flash(:error, gettext("Please log in to claim a company page."))
        |> redirect(to: ~p"/login")
    end
  end

  def edit(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.CompanyLive.Edit, &Companies.can_edit_page?/2)

  def roles(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.CompanyLive.Roles, &Companies.can_manage_roles?/2)

  def domains(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.CompanyLive.Domains, &Companies.can_manage_domains?/2)

  # Shared gate for the owner/admin management pages: log-in required, then the
  # per-page permission (`can?`); otherwise a 404 (never reveal the page exists).
  defp manage(conn, slug, live_view, can?) do
    viewer = conn.assigns[:current_user]
    company = viewer && Companies.get_company_by_slug(slug)

    cond do
      is_nil(viewer) ->
        conn
        |> put_flash(:error, gettext("Please log in first."))
        |> redirect(to: ~p"/login")

      company && can?.(company, viewer) ->
        conn
        |> put_layout(html: false)
        |> live_render(live_view,
          session: Map.put(base_session(conn), "company_id", company.id)
        )

      true ->
        ControllerHelpers.render_error(conn, 404)
    end
  end

  # The agent formats render the anonymous public view, so they 404 for any
  # page that is not active + geo? (pending / frozen / archived / geo? off) no
  # matter who asks — cache-safe, like a hidden profile's siblings.
  defp send_company_doc(conn, format, company) do
    if Companies.agent_visible?(company) do
      domains = Companies.verified_domains(company)
      aliases = Companies.list_aliases(company)
      # The People section under the same public-listing gate (issue #931). The
      # crawlable set is capped generously; the HTML page's "Load more" reaches
      # the tail, and `people_total` carries the true count.
      people = Companies.company_people_page(company, limit: 200)
      total = Companies.company_people_count(company)

      AgentDocs.send_doc(
        conn,
        format,
        CompanyDoc.build_show(company, domains, aliases, people.entries, total)
      )
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
