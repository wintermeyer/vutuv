defmodule VutuvWeb.OrganizationLive.Show do
  @moduledoc """
  A verified organization page (`/organizations/:slug`, issue #929). Embedded via
  `live_render` from `VutuvWeb.OrganizationController` (off-router, like the
  profile); the agent-format siblings stay controller-owned.

  For a public viewer it shows the read-only page (logo, name, verified-domain
  badge, description, address, website) plus the like / bookmark controls
  (reload-free `phx-click`, the like count live over PubSub). The owner of a
  still-`pending` page sees the domain-verification panel instead (resume the
  claim), and a frozen page keeps only the owner + admins, behind the moderation
  banner.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents
  import VutuvWeb.VerificationComponents, only: [check_report: 1]
  import VutuvWeb.FediverseComponents, only: [follow_us_from_elsewhere: 1]
  import VutuvWeb.JobComponents, only: [job_card: 1]
  import VutuvWeb.PostComponents, only: [post_card: 1]

  alias Vutuv.Countries
  alias Vutuv.Fediverse
  alias Vutuv.Jobs
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Social
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.JsonLd
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.VerificationComponents

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    current_user = socket.assigns.current_user

    organization = Organizations.get_organization!(session["organization_id"])
    if connected?(socket), do: Organizations.subscribe(organization.id)

    socket =
      socket
      |> assign_organization(organization, current_user)
      |> assign_people(organization)
      |> assign_org_jobs(organization)
      |> assign(:post_body, "")
      # What the last domain check saw (issue #1466). A socket assign rather
      # than a flash: it is the answer to a question the member just asked and
      # it has to survive on the page, where a toast auto-dismisses and a repeat
      # of the identical toast renders no diff at all.
      |> assign(:check_report, nil)
      |> assign_org_posts(organization)

    {:ok, socket}
  end

  # The organization's own posts (issue #1334), newest first, with their own
  # "Load more" so it never collides with the People or Jobs lists'.
  defp assign_org_posts(socket, organization) do
    page = Posts.organization_posts_page(organization, socket.assigns.current_user)

    socket
    |> assign(:posts, page.entries)
    |> assign(:posts_total, page.total)
    |> assign(:posts_more?, page.more?)
    |> assign(:posts_offset, page.next_offset)
  end

  # The organization page's "Offene Stellen" section (#933): the organization's
  # own live public postings, newest first, paginated (its own "Load more" event
  # so it never collides with the People list's). Static cards — the board is
  # where the like / bookmark actions live (they would clash with the page's own
  # organization-level toggle_like/toggle_bookmark here).
  defp assign_org_jobs(socket, organization) do
    viewer = socket.assigns.current_user
    total = Jobs.organization_postings_count(organization, viewer)

    page =
      if total > 0,
        do: Jobs.list_organization_postings(organization, viewer),
        else: %{entries: [], more?: false, next_offset: 0}

    socket
    |> assign(:org_jobs, page.entries)
    |> assign(:org_jobs_total, total)
    |> assign(:org_jobs_more?, page.more?)
    |> assign(:org_jobs_offset, page.next_offset)
  end

  # The organization page's "People" section (issue #931): members whose linked work
  # experience is at this organization, current members first. Loaded once at mount
  # (state-transition events keep their own paging); "Load more" appends the next
  # page. The list honors the member-directory privacy gate in the context.
  defp assign_people(socket, organization) do
    total = Organizations.organization_people_count(organization)

    page =
      if total > 0,
        do: Organizations.organization_people_page(organization),
        else: %{entries: [], more?: false, next_offset: 0}

    socket
    |> assign(:people, page.entries)
    |> assign(:people_total, total)
    |> assign(:people_more?, page.more?)
    |> assign(:people_offset, page.next_offset)
  end

  # Am I currently speaking as the very page I am looking at? Then a "Message"
  # button would open a conversation with myself. Takes the two things it
  # compares rather than the whole assigns map, so the template expression stays
  # change-tracked and the clause head cannot drift from `follower_of/1`'s.
  defp own_page?(%Organization{id: id}, %Organization{id: id}), do: true
  defp own_page?(_acting_as, _organization), do: false

  defp assign_organization(socket, organization, viewer) do
    # One query for every domain, partitioned in memory (an organization has few).
    domains = Organizations.list_domains(organization)
    primary = Enum.find(domains, & &1.primary?)
    # …and one for every permission answer this page needs. Asked separately
    # these were five reads of the same single row set.
    powers = Organizations.role_powers(organization, viewer)

    socket
    |> assign(:organization, organization)
    |> assign(:page_title, organization.name)
    |> assign(:verified_domains, Enum.filter(domains, & &1.verified_at))
    |> assign(:primary_domain, primary)
    |> assign(:aliases, Organizations.list_aliases(organization))
    |> assign(:country_name, Countries.name(organization.country))
    |> assign(:can_manage?, powers.can_manage?)
    |> assign(:can_edit?, powers.can_edit?)
    |> assign(:owner?, powers.owner?)
    # Never implied by owner or admin (issue #1333): speaking for the page is
    # its own grant, so `role_powers/2` reads it from the role list on its own
    # rather than deriving it from the two above.
    |> assign(:publisher?, powers.publisher?)
    # Following a page (issue #1336): a private subscription that pulls its
    # posts into your feed. No approval and no notification — a page has no
    # inbox to be told, the same way following a member needs no permission.
    # While acting as another page, the pill follows **as that page** (the last
    # writer #1336 needed): the follow belongs to whoever is speaking, and the
    # feed it fills is that page's. `follower_of/1` is the one place that
    # decides, so the state, the toggle and the label cannot disagree.
    |> assign(
      :following?,
      follows?(
        follower_of(%{
          acting_as: socket.assigns[:acting_as],
          organization: organization,
          current_user: viewer
        }),
        organization
      )
    )
    |> assign(:follower_count, Social.organization_follower_count(organization))
    |> assign(:pending?, organization.status == "pending")
    |> assign(:frozen?, not is_nil(organization.frozen_at))
    # The page's Fediverse address, or nil (issue #1334). `federated?/1` already
    # answers for a page — installation switch, its own opt-in, a claimed handle
    # and public visibility — so this is a field read and costs no query. Unlike
    # a member there is no `moved_to` arm: moving an account elsewhere is a
    # person's decision about their own identity and a page carries no such
    # column, so the card never has a forwarding address to show.
    |> assign(
      :fediverse,
      if(Fediverse.federated?(organization), do: %{handle: Docs.handle(organization)})
    )
    # Whether to offer the owner the switch instead of an address. Read off the
    # same two facts the card needs, so the template asks no questions of its
    # own: the installation must federate at all, and this must be the owner
    # (federating decides how the page appears on servers we do not run, which
    # is why the switch itself is owner-only rather than publisher-wide).
    |> assign(:fediverse_invite?, Fediverse.enabled?() and powers.owner?)
    |> assign(:engagement, Organizations.organization_engagement(organization, viewer))
    |> assign(:dns_value, primary && Organizations.dns_txt_value(primary))
    |> assign(:dns_challenge_name, primary && Organizations.dns_challenge_name(primary))
    |> assign(:well_known_url, primary && Organizations.well_known_url(primary))
    |> assign(:well_known_content, primary && Organizations.well_known_content(primary))
    |> assign(:verification_enabled?, Organizations.verification_enabled?())
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Organizations.organization_people_page(socket.assigns.organization,
        offset: socket.assigns.people_offset
      )

    {:noreply,
     socket
     |> assign(:people, socket.assigns.people ++ page.entries)
     |> assign(:people_more?, page.more?)
     |> assign(:people_offset, page.next_offset)}
  end

  def handle_event("toggle-follow", _params, socket) do
    organization = socket.assigns.organization
    follower = follower_of(socket.assigns)

    if follower do
      toggle_follow(follower, organization, socket.assigns.following?)

      {:noreply,
       socket
       |> assign(:following?, follows?(follower, organization))
       |> assign(:follower_count, Social.organization_follower_count(organization))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("publish", %{"body" => body}, socket) do
    organization = socket.assigns.organization

    # The role is re-checked by `create_organization_post/3` itself, so a
    # withdrawn publisher cannot post through a page they still have open.
    case Posts.create_organization_post(organization, socket.assigns.current_user, %{body: body}) do
      {:ok, _post} ->
        {:noreply,
         socket
         |> assign(:post_body, "")
         |> assign_org_posts(organization)
         |> put_flash(:info, gettext("Published as %{name}.", name: organization.name))}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:publisher?, false)
         |> put_flash(:error, gettext("You may no longer write in this organization's name."))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:post_body, body)
         |> put_flash(:error, gettext("That post could not be published."))}
    end
  end

  def handle_event("load-more-posts", _params, socket) do
    page =
      Posts.organization_posts_page(socket.assigns.organization, socket.assigns.current_user,
        offset: socket.assigns.posts_offset
      )

    {:noreply,
     socket
     |> assign(:posts, socket.assigns.posts ++ page.entries)
     |> assign(:posts_more?, page.more?)
     |> assign(:posts_offset, page.next_offset)}
  end

  def handle_event("load-more-jobs", _params, socket) do
    page =
      Jobs.list_organization_postings(
        socket.assigns.organization,
        socket.assigns.current_user,
        offset: socket.assigns.org_jobs_offset
      )

    {:noreply,
     socket
     |> assign(:org_jobs, socket.assigns.org_jobs ++ page.entries)
     |> assign(:org_jobs_more?, page.more?)
     |> assign(:org_jobs_offset, page.next_offset)}
  end

  def handle_event("toggle_like", _params, socket), do: {:noreply, toggle(socket, :like)}

  def handle_event("toggle_bookmark", _params, socket), do: {:noreply, toggle(socket, :bookmark)}

  def handle_event("set_method", %{"method" => method}, socket)
      when method in ~w(dns well_known) do
    if socket.assigns.can_edit? and socket.assigns.pending? do
      {:ok, _domain} = Organizations.set_domain_method(socket.assigns.primary_domain, method)

      # The old report was about the other method, so it would now be answering
      # a question nobody asked.
      {:noreply,
       socket
       |> assign(:check_report, nil)
       |> assign_organization(socket.assigns.organization, socket.assigns.current_user)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("verify", _params, socket) do
    if socket.assigns.can_edit? and socket.assigns.pending? do
      organization = socket.assigns.organization
      domain = socket.assigns.primary_domain

      case Organizations.check_domain(organization, domain) do
        {:ok, organization} ->
          {:noreply,
           socket
           |> assign(:check_report, nil)
           |> assign_organization(organization, socket.assigns.current_user)
           |> put_flash(:info, gettext("Your organization page is verified and now live."))}

        {:error, report} ->
          {:noreply, assign(socket, :check_report, VerificationComponents.stamp(report))}
      end
    else
      {:noreply, socket}
    end
  end

  # Who the follow belongs to: the page being acted as, else the member. A page
  # can never follow itself, so acting as *this* page falls back to nobody
  # rather than offering a control that could only fail.
  defp follower_of(%{acting_as: %Organization{id: id}, organization: %Organization{id: id}}),
    do: nil

  defp follower_of(%{acting_as: %Organization{} = page}), do: page
  defp follower_of(%{current_user: viewer}), do: viewer

  defp follows?(nil, _organization), do: false

  defp follows?(%Organization{} = page, organization),
    do: Social.organization_follows?(page, organization)

  defp follows?(viewer, organization), do: Social.follows_organization?(viewer, organization)

  defp toggle_follow(%Organization{} = page, organization, true),
    do: Social.unfollow_as_organization(page, organization)

  defp toggle_follow(%Organization{} = page, organization, false),
    do: Social.follow_as_organization(page, organization)

  defp toggle_follow(viewer, organization, true),
    do: Social.unfollow_organization(viewer, organization)

  defp toggle_follow(viewer, organization, false),
    do: Social.follow_organization(viewer, organization)

  @impl true
  def handle_info({:organization_counters, %{likes: likes}}, socket) do
    {:noreply, assign(socket, :engagement, %{socket.assigns.engagement | likes: likes})}
  end

  # The background pass finished the claim (issue #1466). Somebody who published
  # the record and left this tab open watches the panel turn into their page,
  # which is the clearest possible answer to "is it working yet".
  def handle_info({:organization_verified, _id}, socket) do
    organization = Organizations.get_organization!(socket.assigns.organization.id)

    {:noreply,
     socket
     |> assign(:check_report, nil)
     |> assign_organization(organization, socket.assigns.current_user)
     |> put_flash(:info, gettext("Your organization page is verified and now live."))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # `primary_domain` is a %OrganizationDomain{} struct here (the assign holds the row
  # for the verify panel); set_method/verify need the struct, so re-fetch it.
  defp toggle(socket, kind) do
    case socket.assigns.current_user do
      nil ->
        push_navigate(socket, to: ~p"/login")

      user ->
        organization = socket.assigns.organization
        Organizations.toggle_engagement(kind, user, organization, socket.assigns.engagement)
        assign(socket, :engagement, Organizations.organization_engagement(organization, user))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 py-6">
      <.frozen_banner :if={@can_manage? and @frozen?} class="rounded-2xl px-4 py-3 text-sm">
        {gettext("This organization page was reported and is hidden while it is reviewed. Only you and the moderators can see it.")}
      </.frozen_banner>

      <%= if @can_edit? and @pending? do %>
        {verify_panel(assigns)}
      <% else %>
        {public_page(assigns)}
      <% end %>
    </div>
    """
  end

  defp public_page(assigns) do
    ~H"""
    <div>
      <JsonLd.script
        :if={Organizations.indexable?(@organization)}
        data={JsonLd.organization_page(@organization, @verified_domains)}
      />

      <div class="flex flex-col gap-6 md:grid md:grid-cols-3">
        <div class="min-w-0 md:col-span-2 md:space-y-6">
          <.card>
            <div class="flex items-start gap-4">
              <.organization_logo organization={@organization} class="h-20 w-20 shrink-0" />
              <div class="min-w-0 flex-1">
                <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{@organization.name}</h1>
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <.kind_badge kind={@organization.kind} />
                  <.verified_badge :if={@primary_domain} domain={@primary_domain.domain} />
                </div>
                <.organization_location organization={@organization} class="mt-2 text-sm text-slate-600 dark:text-slate-400" />
                <a
                  :if={@organization.website_url}
                  href={@organization.website_url}
                  rel="nofollow noopener"
                  target="_blank"
                  class="mt-2 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >
                  {display_url(@organization.website_url)}
                </a>

                <%!-- The Fediverse address where a visitor scans for "where else
                is this page". The card at the foot of the column carries the
                whole explanation — copy button and remote-follow tool — and
                repeating that here would say the same thing twice on one screen,
                so this is one line that names the address and jumps to it. It is
                the shortcut row the member profile keeps in its Profiles card:
                the card alone was not findable, which is what was reported. --%>
                <a
                  :if={@fediverse}
                  id="organization-fediverse-shortcut"
                  href="#organization-subscribe"
                  class="group mt-2 flex items-center gap-2 text-sm text-slate-700 transition hover:text-brand-700 dark:text-slate-200"
                >
                  <.detail_icon
                    name="globe"
                    class="h-4 w-4 shrink-0 text-slate-400 transition group-hover:text-brand-600 dark:text-slate-500 dark:group-hover:text-brand-300"
                  />
                  <span class="truncate font-medium">{@fediverse.handle}</span>
                  <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400">
                    {gettext("Follow")} ›
                  </span>
                </a>
              </div>
            </div>

            <div class="mt-6 flex flex-wrap items-center gap-4 border-t border-slate-100 pt-4 dark:border-slate-800">
              <%!-- Following a page (issue #1336). The same "one control, two
              states" pill the member and tag follows use, so the act reads the
              same wherever it appears: brand outline while you do not follow, a
              calm slate "Following" that turns rose and says "Unfollow" on
              hover once you do. `min-h-10` because it stands alone in a page
              header rather than in a dense list row. --%>
              <button
                :if={@current_user}
                type="button"
                id="organization-follow"
                phx-click="toggle-follow"
                aria-pressed={to_string(@following?)}
                class={[
                  "group inline-flex min-h-10 min-w-[7rem] items-center justify-center gap-1.5 rounded-full border px-4 text-sm font-semibold transition-colors",
                  if(@following?,
                    do:
                      "border-slate-300 text-slate-700 hover:border-rose-300 hover:bg-rose-50 hover:text-rose-700 dark:border-slate-600 dark:text-slate-200 dark:hover:border-rose-500/60 dark:hover:bg-rose-950/40 dark:hover:text-rose-300",
                    else:
                      "border-brand-600 text-brand-700 hover:bg-brand-50 dark:border-brand-400 dark:text-brand-300 dark:hover:bg-brand-900/40"
                  )
                ]}
              >
                <span :if={!@following?}>{gettext("Follow")}</span>
                <span :if={@following?} class="group-hover:hidden group-focus:hidden">
                  {gettext("Following")}
                </span>
                <span :if={@following?} class="hidden group-hover:inline group-focus:inline">
                  {gettext("Unfollow")}
                </span>
              </button>

              <%!-- Writing to the page (issue #1336). A quiet secondary next to
              the follow pill: following is the act this header is built around,
              and a second brand-weight control beside it would make the reader
              choose. Hidden while you are writing AS this page, where it would
              offer a conversation with yourself. --%>
              <.link
                :if={@current_user && not own_page?(@acting_as, @organization)}
                navigate={~p"/messages/organization/#{@organization.slug}"}
                id="message-organization"
                data-message-organization
                class="inline-flex min-h-10 items-center rounded-full bg-slate-100 px-4 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                {gettext("Message")}
              </.link>

              <span
                :if={@follower_count > 0}
                data-organization-followers
                class="text-sm text-slate-600 dark:text-slate-400"
              >
                {ngettext("%{formatted} follower", "%{formatted} followers", @follower_count,
                  formatted: compact_count(@follower_count)
                )}
              </span>

              <.engagement_bar engagement={@engagement} />

              <div class="ml-auto flex flex-wrap items-center gap-4 text-sm">
                <.link
                  :if={@can_edit?}
                  navigate={~p"/organizations/#{@organization.slug}/edit"}
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >
                  {gettext("Edit")}
                </.link>
                <.link
                  :if={@owner?}
                  navigate={~p"/organizations/#{@organization.slug}/roles"}
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >
                  {gettext("Team")}
                </.link>
                <.link
                  :if={@owner?}
                  navigate={~p"/organizations/#{@organization.slug}/domains"}
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >
                  {gettext("Domains")}
                </.link>
                <%!-- This row and the manage pages' tab bar are two hand-kept
                lists of the same map, and they had drifted: the tab bar names
                eight areas, this row named three, and Fediverse was among the
                five an owner could only reach by opening one of the three and
                noticing a tab. Adding one link is the small fix; the real one is
                to render both from a single source, which is a nav change worth
                agreeing on first. Until then, keep them in step by hand. --%>
                <.link
                  :if={@owner?}
                  id="organization-manage-fediverse"
                  navigate={~p"/organizations/#{@organization.slug}/fediverse"}
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >
                  {gettext("Fediverse")}
                </.link>
                <.link
                  :if={@current_user && !@can_manage?}
                  href={~p"/reports/new?#{[type: "organization", id: @organization.id, return_to: "/organizations/#{@organization.slug}"]}"}
                  class="text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
                >
                  {gettext("Report")}
                </.link>
              </div>
            </div>
          </.card>

          <.card :if={present?(@organization.description)}>
            <.section_title>{gettext("About")}</.section_title>
            <.markdown_prose text={@organization.description} class="mt-3 text-slate-800 dark:text-slate-200" />
          </.card>

          <%!-- Posts published in the organization's name (issue #1334). The
          card shows for every viewer once there is something in it, and for a
          publisher even when there is not — an empty card with a composer is
          how they find out they may write here at all. --%>
          <.card :if={@posts_total > 0 or @publisher?} id="organization-posts">
            <div class="flex items-center justify-between gap-3">
              <.section_title>{gettext("Posts")}</.section_title>
              <div class="flex items-center gap-3">
                <span :if={@posts_total > 0} class="text-sm text-slate-600 dark:text-slate-400">
                  {compact_count(@posts_total)}
                </span>
                <%!-- One sign to the Subscribe card at the foot of the column,
                which holds both ways to follow this page from outside vutuv —
                the Fediverse address and the feed — exactly as the member
                profile does. Rendered when that card renders, so the anchor is
                never a dead jump. --%>
                <.subscribe_link
                  :if={subscribe_card?(@fediverse, @fediverse_invite?, @posts_total)}
                  id="organization-subscribe-link"
                  href="#organization-subscribe"
                />
              </div>
            </div>

            <%!-- Switching into the organization for the rest of the session
            (issue #1335), offered where a publisher already is. A CSRF POST,
            never a GET: a request that changes whose name you speak in must not
            fire on a link prefetch or a Back button. --%>
            <.link
              :if={@publisher? and !@acting_as}
              href={~p"/organizations/#{@organization.slug}/act_as"}
              method="post"
              id="start-acting-as"
              class="mt-3 inline-flex min-h-10 items-center rounded-lg bg-slate-100 px-4 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              {gettext("Write as %{name} for now", name: @organization.name)}
            </.link>

            <%!-- The composer names the author right at the point of publishing,
            in the button, because the characteristic failure of writing under a
            brand is forgetting whose name is on it. --%>
            <.form
              :if={@publisher?}
              for={%{}}
              id="organization-post-form"
              phx-submit="publish"
              class="mt-3 space-y-3"
            >
              <textarea
                name="body"
                rows="3"
                placeholder={gettext("Write something as %{name}", name: @organization.name)}
                class={[input_class(), "resize-y"]}
              >{@post_body}</textarea>
              <div class="flex justify-end">
                <button
                  type="submit"
                  class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
                >
                  {gettext("Post as %{name}", name: @organization.name)}
                </button>
              </div>
            </.form>

            <div :if={@posts != []} class="mt-4 divide-y divide-slate-100 dark:divide-slate-800">
              <div :for={post <- @posts} class="py-4 first:pt-0 last:pb-0">
                <.post_card
                  post={post}
                  viewer={@current_user}
                  conn_or_socket={@socket}
                  mode={:preview}
                  surface={:flat}
                />
              </div>
            </div>

            <p :if={@posts == [] and @publisher?} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
              {gettext("Nothing published yet.")}
            </p>

            <div :if={@posts_more?} class="mt-4 text-center">
              <.button variant="secondary" phx-click="load-more-posts" id="load-more-posts">
                {gettext("Load more")}
              </.button>
            </div>
          </.card>

          <%!-- People: members who list this organization as an employer (issue #931).
          Current members lead; a "Former" tag marks past ones. Plain profile
          links make each profile crawlable from the organization page. --%>
          <.card :if={@people_total > 0}>
            <div class="flex items-center justify-between">
              <.section_title>{gettext("People")}</.section_title>
              <span class="text-sm text-slate-600 dark:text-slate-400">{compact_count(@people_total)}</span>
            </div>
            <ul id="organization-people" class="mt-4 space-y-3">
              <li :for={person <- @people} class="flex items-center gap-3">
                <.avatar user={person.user} size="sm" shape="circle" />
                <div class="min-w-0">
                  <a
                    href={"/" <> person.user.username}
                    class="font-semibold text-slate-900 hover:text-brand-700 dark:text-slate-100 dark:hover:text-brand-400"
                  >
                    {UserHelpers.full_name(person.user)}
                  </a>
                  <p class="truncate text-sm text-slate-600 dark:text-slate-400">
                    {person.title}<span :if={not person.current?} class="text-slate-500 dark:text-slate-500">
                      · {gettext("Former")}</span>
                  </p>
                </div>
              </li>
            </ul>
            <.load_more :if={@people_more?} class="mt-4" />
          </.card>

          <%!-- Open positions (#933): this organization's live public postings.
          Plain profile-style cards linking each detail page, so every posting is
          crawlable from the organization page; the board is where the filters and
          the like / bookmark actions live. --%>
          <section :if={@org_jobs_total > 0} class="space-y-4">
            <div class="flex items-center justify-between">
              <.section_title>{gettext("Open positions")}</.section_title>
              <span class="text-sm text-slate-600 dark:text-slate-400">{compact_count(@org_jobs_total)}</span>
            </div>
            <div id="organization-jobs" class="grid gap-4 sm:grid-cols-2">
              <.job_card :for={posting <- @org_jobs} posting={posting} />
            </div>
            <div :if={@org_jobs_more?} class="text-center">
              <button
                type="button"
                id="load-more-jobs"
                phx-click="load-more-jobs"
                class="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                {gettext("More jobs")}
              </button>
            </div>
          </section>

          <%!-- Subscribe: the one card that answers "how do I follow this page
          without a vutuv account", with both ways to do it. Same card, same
          wording and the same `<.subscribe_card>` as a member's profile: a
          visitor arriving from Mastodon asks the same thing of a person and of
          a page, and until the Fediverse half shipped the page answered it
          nowhere — its handle existed, was WebFingered, and appeared on no page
          a human reads. `@fediverse` is nil unless the page federates, which is
          off until an owner switches it on, so most pages show the feed alone.

          It closes the main column for the profile's reason: the page itself is
          what a visitor came for and this is the "take me with you" footer under
          it. The header card's one-line shortcut and the Posts card's sign are
          what make it findable without scrolling.

          Without an address the Fediverse half is an EMPTY SECTION, and this app
          teaches an empty section to its owner rather than hiding it: the same
          dashed `<.empty_add>` scaffold every profile section shows while it has
          nothing in it. It is needed here more than anywhere, because the switch
          is otherwise unreachable by accident — it lives behind the manage tab
          bar, which renders only on the manage pages themselves, so an owner had
          to open "Edit" and notice a tab to learn that a page can federate at
          all. Owners only, and only where the installation federates: a visitor
          has nothing to do with it, and where the operator switched federation
          off there is nothing to switch on. --%>
          <.subscribe_card
            id="organization"
            feed_href={
              @posts_total > 0 && VutuvWeb.Feeds.organization_feed_path(@organization)
            }
          >
            <:fediverse :if={@fediverse || @fediverse_invite?}>
              <%= if @fediverse do %>
                <.follow_us_from_elsewhere
                  id="organization-fediverse"
                  handle={@fediverse.handle}
                  name={@organization.name}
                  action={~p"/organizations/#{@organization.slug}/fediverse/follow"}
                />
              <% else %>
                <%!-- Says what this does for the organization before it names
                anything: reach past vutuv. "Fediverse" is the heading and the
                word the owner will meet again on the switch page and in the tab
                bar, so it is worth teaching once, in the one place where it is
                explained. The first sentence is shared with that switch page
                (one msgid), so the offer and the page it leads to cannot
                describe the same thing in two different ways. The second is the
                mental model people actually have for an `@name@host`
                address. --%>
                <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
                  {gettext(
                    "People who have no vutuv account can follow this page and read its posts, in networks like Mastodon."
                  )}
                </p>
                <p class="mt-2 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
                  {gettext(
                    "The page gets an address of its own for that, written like an email address."
                  )}
                </p>
                <.empty_add
                  href={~p"/organizations/#{@organization.slug}/fediverse"}
                  id="organization-fediverse-enable"
                  class="mt-3"
                >
                  {gettext("Set this page up for other networks")}
                </.empty_add>
              <% end %>
            </:fediverse>
          </.subscribe_card>
        </div>

        <aside class="space-y-6">
          <.card>
            <.section_title>{gettext("Address")}</.section_title>
            <address class="mt-3 space-y-0.5 text-sm not-italic text-slate-700 dark:text-slate-300">
              <div :if={present?(@organization.street_address)}>{@organization.street_address}</div>
              <div>{[@organization.zip_code, @organization.city] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")}</div>
              <div :if={present?(@organization.state)}>{@organization.state}</div>
              <div>{@country_name}</div>
            </address>
          </.card>

          <.card :if={@aliases != []}>
            <.section_title>{gettext("Also known as")}</.section_title>
            <ul class="mt-3 flex flex-wrap gap-2">
              <li
                :for={organization_name <- @aliases}
                class="rounded-lg bg-slate-100 px-2.5 py-1 text-sm font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-200"
              >
                {organization_name.name}
              </li>
            </ul>
          </.card>

          <.card :if={length(@verified_domains) > 1}>
            <.section_title>{gettext("Verified domains")}</.section_title>
            <ul class="mt-3 space-y-1 text-sm text-slate-700 dark:text-slate-300">
              <li :for={domain <- @verified_domains}>{domain.domain}</li>
            </ul>
          </.card>

          <.other_formats_card
            base_path={"/organizations/" <> @organization.slug}
            locale={@locale}
            machine_formats={@organization.geo?}
          />
        </aside>
      </div>
    </div>
    """
  end

  defp verify_panel(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl">
      <.card>
        <h1 class="text-xl font-bold text-slate-900 dark:text-slate-100">
          {gettext("Verify %{name}", name: @organization.name)}
        </h1>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Prove you control %{domain} to publish this page.", domain: @primary_domain.domain)}
        </p>

        <%!-- Reassure the member who cannot touch DNS themselves: they can hand
        the record below to whoever runs their website and finish here later. --%>
        <p
          :if={@verification_enabled?}
          class="mt-4 rounded-lg bg-brand-50 p-4 text-sm text-slate-700 ring-1 ring-brand-100 dark:bg-brand-900/30 dark:text-slate-300 dark:ring-brand-900/50"
        >
          {gettext("These steps are technical. If you don't manage %{domain} yourself, copy the record or file shown below and send it to your IT team or whoever runs your website. Once they have added it, come back here and press Verify now.", domain: @primary_domain.domain)}
        </p>

        <%= if @verification_enabled? do %>
          <fieldset class="mt-6">
            <legend class="text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("Verification method")}
            </legend>
            <div class="mt-2 flex flex-col gap-2">
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="method"
                  value="dns"
                  checked={@primary_domain.method == "dns"}
                  phx-click="set_method"
                  phx-value-method="dns"
                  class={checkbox_class()}
                /> {gettext("DNS TXT record")}
              </label>
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="method"
                  value="well_known"
                  checked={@primary_domain.method == "well_known"}
                  phx-click="set_method"
                  phx-value-method="well_known"
                  class={checkbox_class()}
                /> {gettext("Website file")}
              </label>
            </div>
          </fieldset>

          <div class="mt-4 rounded-lg bg-slate-50 p-4 text-sm dark:bg-slate-800/60">
            <%= if @primary_domain.method == "dns" do %>
              <p class="text-slate-700 dark:text-slate-300">
                {gettext("In your DNS settings, create a TXT record on the name %{domain} with this value:",
                  domain: @primary_domain.domain
                )}
              </p>
              <code
                phx-no-curly-interpolation
                class="mt-2 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"
              ><%= @dns_value %></code>
              <p class="mt-2 text-xs text-slate-600 dark:text-slate-400">
                {gettext("If %{domain} is a CNAME / alias (a TXT record cannot share a name with a CNAME), put the record on %{name} instead, with the same value.",
                  domain: @primary_domain.domain,
                  name: @dns_challenge_name
                )}
              </p>
            <% else %>
              <p class="text-slate-700 dark:text-slate-300">
                {gettext("Serve this file at:")}
              </p>
              <code
                phx-no-curly-interpolation
                class="mt-2 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"
              ><%= @well_known_url %></code>
              <p class="mt-3 text-slate-700 dark:text-slate-300">{gettext("with this exact content:")}</p>
              <code
                phx-no-curly-interpolation
                class="mt-2 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"
              ><%= @well_known_content %></code>
            <% end %>
          </div>

          <%!-- `phx-disable-with` is the whole feedback a member gets while the
          check runs, and the check is a DNS or HTTP round trip that can take
          seconds. Without it the button sits there unchanged and the click
          reads as swallowed, which is half of what issue #1466 reported. --%>
          <button
            type="button"
            phx-click="verify"
            phx-disable-with={gettext("Checking …")}
            id="verify-domain"
            class="mt-6 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700 disabled:opacity-60"
          >
            {gettext("Verify now")}
          </button>

          <.check_report
            id="verify-domain-report"
            report={@check_report}
            disabled_text={gettext("Domain verification is disabled on this installation.")}
          />
          <.check_reassurance
            :if={is_nil(@primary_domain.verified_at)}
            domain={@primary_domain.domain}
          />
        <% else %>
          <p class="mt-6 rounded-lg bg-amber-50 px-4 py-3 text-sm text-amber-800 dark:bg-amber-900/30 dark:text-amber-200">
            {gettext("Domain verification is disabled on this installation.")}
          </p>
        <% end %>
      </.card>
    </div>
    """
  end

  # Does the page show a Subscribe card — and therefore its Posts-header sign?
  # One predicate rather than the same boolean written at both sites: the card
  # renders for any of its halves (a Fediverse address, an owner's invite to
  # switch federation on, a feed with posts behind it), and the header's
  # `<.subscribe_link>` must point at it exactly when it is there, or the anchor
  # is a jump to nothing.
  defp subscribe_card?(fediverse, fediverse_invite?, posts_total),
    do: fediverse != nil or fediverse_invite? or posts_total > 0

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp display_url(url),
    do: url |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")
end
