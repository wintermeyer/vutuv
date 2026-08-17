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

  alias Vutuv.Fediverse
  alias Vutuv.Organizations
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.OrganizationDoc
  alias VutuvWeb.AgentDocs.PostDoc
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.FediverseController

  def index(conn, _params) do
    case AgentDocs.negotiate(conn) do
      :html ->
        session =
          ControllerHelpers.live_render_session(conn)
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
    cond do
      # An ActivityPub Accept on the page URL gets the actor document — what
      # Mastodon fetches when somebody pastes the page's address into its search,
      # which is the other half of showing that address on the page at all. A
      # page that does not federate gets the same refusal its actor endpoint
      # gives (410 once its owner switched federation off, so remote servers drop
      # their copies; 404 otherwise), which reads to an AP client as "nothing
      # here" rather than choking on HTML. The member twin is `UserController`.
      FediverseController.ap_request?(conn) and Fediverse.federated?(organization) ->
        {:ok, actor} = Fediverse.ensure_organization_actor(organization)

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode!(Docs.organization_actor(organization, actor)))

      FediverseController.ap_request?(conn) ->
        FediverseController.refuse(conn, organization)

      true ->
        render_page_document(conn, organization)
    end
  end

  defp render_page_document(conn, organization) do
    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> put_organization_canonical(organization)
        |> AgentDocs.put_html_alternates()
        |> put_layout(html: false)
        |> live_render(VutuvWeb.OrganizationLive.Show,
          session:
            Map.put(
              ControllerHelpers.live_render_session(conn),
              "organization_id",
              organization.id
            )
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
        |> live_render(VutuvWeb.OrganizationLive.New,
          session: ControllerHelpers.live_render_session(conn)
        )

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

  @doc """
  The owner's federation switch (issue #1334). Owner-only, unlike the feed and
  the following list: it decides how the page appears on servers we do not run,
  and it cannot be fully taken back.
  """
  def fediverse(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Fediverse, &Organizations.owner?/2)

  @doc """
  Who follows the page from other networks. Owner-only like the switch it hangs
  off: these are names of people who never signed up here, and the page itself
  publishes only the count.
  """
  def fediverse_followers(conn, %{"slug" => slug}),
    do:
      manage(
        conn,
        slug,
        VutuvWeb.OrganizationLive.FediverseFollowers,
        &Organizations.owner?/2
      )

  @doc """
  Whether a Mastodon-compatible app may act as this page. Owner-only like
  federating beside it, and its own page for the same reason it is its own tab:
  publishing to other servers and letting the team use a phone app are two
  decisions, not one.
  """
  def apps(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Apps, &Organizations.owner?/2)

  def exclusions(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Exclusions, &Organizations.can_manage?/2)

  def activity(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Activity, &Organizations.can_manage?/2)

  @doc """
  What the page reads (issue #1336). **Publishers only**, where the activity
  list above takes any role holder: activity is news about the page, this is
  the page's own reading, which is part of speaking for it.
  """
  def feed(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Feed, &Organizations.publisher?/2)

  @doc "What the page follows (issue #1336). Publishers only, like the feed."
  def following(conn, %{"slug" => slug}),
    do: manage(conn, slug, VutuvWeb.OrganizationLive.Following, &Organizations.publisher?/2)

  @doc """
  The permalink of a post published in this organization's name (issue #1334).
  404s for an unknown page, a page this viewer may not see, or an id that is not
  one of its posts — an id belonging to a member's post must not render under an
  organization's name.
  """
  def post(conn, %{"slug" => slug, "id" => id}) do
    viewer = conn.assigns[:current_user]

    with {:ok, organization} <- Organizations.fetch_visible_organization(slug, viewer),
         %Post{} = post <- Posts.get_organization_post(organization, id, viewer) do
      cond do
        # This URL is the **id** every page post carries into the fediverse
        # (`Docs.note_url/2`), so it is what a remote server fetches to verify
        # the object, thread a reply under it or check it still exists. Until
        # this branch existed the accept header fell through to
        # `AgentDocs.negotiate/1`, which knows nothing about
        # `application/activity+json`, and the request 500ed — on the id of
        # every post a page had ever federated. The member permalink
        # (`VutuvWeb.PostController`) has answered the same request with the
        # Note from the start; this is that arrangement for a page.
        FediverseController.ap_request?(conn) and Fediverse.federated?(organization) and
            not Posts.moderation_hidden?(post) ->
          send_note(conn, organization, post)

        FediverseController.ap_request?(conn) ->
          FediverseController.refuse(conn, organization)

        true ->
          send_post_document(conn, organization, post, id)
      end
    else
      _ -> ControllerHelpers.render_error(conn, 404)
    end
  end

  # The ActivityPub rendering of a page's post, the twin of
  # `VutuvWeb.PostController`'s.
  defp send_note(conn, organization, post) do
    note =
      post
      |> Repo.preload(Docs.note_preloads())
      |> Docs.note(organization)
      |> Map.put("@context", "https://www.w3.org/ns/activitystreams")

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, Jason.encode!(note))
  end

  defp send_post_document(conn, organization, post, id) do
    case AgentDocs.negotiate(conn) do
      :html ->
        conn
        |> AgentDocs.put_html_alternates()
        |> put_layout(html: false)
        |> live_render(VutuvWeb.OrganizationLive.Post,
          session:
            conn
            |> ControllerHelpers.live_render_session()
            |> Map.put("organization_id", organization.id)
            |> Map.put("post_id", id)
            # Threaded down to the nested `PostLive.Thread` exactly as the
            # member permalink does it (issue #1033): the conversation scrolls
            # itself to the permalinked post on arrival, and the link-preview
            # capture renders from the top, so the jump would store a blank
            # image of this page.
            |> Map.put("auto_scroll", not ControllerHelpers.page_capture?(conn))
        )

      format ->
        send_organization_post_doc(conn, format, organization, post)
    end
  end

  # The agent formats render the **anonymous public** view, like every other doc
  # here, so they 404 for anything a logged-out reader could not open no matter
  # who asks: a page that is not active + `geo?`, and a post still held by
  # moderation — which its own publishers do keep seeing in the HTML.
  defp send_organization_post_doc(conn, format, organization, post) do
    if Organizations.agent_visible?(organization) and not Posts.moderation_hidden?(post) do
      AgentDocs.send_doc(conn, format, PostDoc.build_organization_post(organization, post))
    else
      ControllerHelpers.render_error(conn, 404)
    end
  end

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
          session:
            Map.put(
              ControllerHelpers.live_render_session(conn),
              "organization_id",
              organization.id
            )
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
end
