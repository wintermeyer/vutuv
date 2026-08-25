defmodule VutuvWeb.OrganizationLive.Following do
  @moduledoc """
  What a page follows (`/organizations/:slug/following`, issue #1336) — the
  list behind the feed beside it, and the only place its team can take a
  subscription back.

  **Publishers only**, like the feed and for the same reason: this is the
  page's own reading, which is part of speaking for it, not news about it.

  Deliberately **not public**, unlike a member's Following page. What a page
  reads is working material — which competitors and topics a company watches
  says more about its plans than a member's reading list says about theirs —
  and nothing in #1336 asks for it to be on show. Making it public later is an
  easy step; taking it back would not be.

  **Accounts on other networks live here too**, not on the Fediverse page beside
  it. A member's equivalent sits under their fediverse settings because their
  own following list is public and about people here; this page is already
  publishers-only and already mixes members, pages and topics, so one list of
  "what this page reads" is the honest shape — and it is exactly what the page's
  feed is built from. The section shows only while the page federates, because
  asking to follow somebody out there is impossible otherwise.

  Embedded via `live_render` from `VutuvWeb.OrganizationController`, which gates
  it before this ever mounts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents,
    only: [manage_header: 1, organization_location: 1]

  import VutuvWeb.UserHelpers, only: [author_name: 1]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.MastodonApi
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.Tags
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:organization, organization)
     |> assign(:page_title, gettext("Follows – %{name}", name: organization.name))
     |> assign(:local_form, local_form())
     |> assign(:local_follow_error, nil)
     |> assign(:remote_form, remote_form())
     |> assign(:follow_error, nil)
     |> load_following()}
  end

  defp load_following(socket) do
    organization = socket.assigns.organization

    socket
    |> assign(:followees, Social.organization_followee_entries(organization))
    |> assign(:tags, Tags.organization_followed_tags(organization))
    |> assign(:federated?, Fediverse.federated?(organization))
    |> assign(:remote_follows, Fediverse.list_organization_remote_follows(organization))
  end

  @impl true
  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    with_publisher(socket, fn organization ->
      # Scoped to this page's own edges: `organization_followees/1` only ever
      # hands out follow ids belonging to it, and the delete re-checks rather
      # than trusting the id that came back from the client.
      Social.unfollow_edge_as_organization(organization, follow_id)

      {:noreply, load_following(socket)}
    end)
  end

  def handle_event("follow-local", %{"local_follow" => %{"account" => address}}, socket) do
    with_publisher(socket, fn organization ->
      case local_account(address) do
        %Organization{id: id} when id == organization.id ->
          {:noreply,
           socket
           |> assign(:local_form, local_form(address))
           |> assign(:local_follow_error, :self)}

        %User{} = account ->
          follow_local(socket, organization, account)

        %Organization{} = account ->
          follow_local(socket, organization, account)

        nil ->
          {:noreply,
           socket
           |> assign(:local_form, local_form(address))
           |> assign(:local_follow_error, :not_found)}
      end
    end)
  end

  def handle_event("typing-local", %{"local_follow" => %{"account" => address}}, socket) do
    {:noreply,
     socket
     |> assign(:local_form, local_form(address))
     |> assign(:local_follow_error, nil)}
  end

  def handle_event("mute", %{"id" => follow_id}, socket),
    do: set_local_mute(socket, follow_id, true)

  def handle_event("unmute", %{"id" => follow_id}, socket),
    do: set_local_mute(socket, follow_id, false)

  def handle_event("unfollow-tag", %{"id" => tag_id}, socket) do
    with_publisher(socket, fn organization ->
      Tags.unfollow_tag_as_organization(organization, tag_id)
      {:noreply, load_following(socket)}
    end)
  end

  def handle_event("follow-remote", %{"remote_follow" => %{"address" => address}}, socket) do
    with_publisher(socket, fn organization ->
      case Fediverse.follow_remote_as_organization(organization, address) do
        {:ok, _follow} ->
          {:noreply,
           socket
           |> assign(:remote_form, remote_form())
           |> assign(:follow_error, nil)
           |> load_following()}

        {:error, reason} ->
          # The address stays in the box: a refusal usually means a typo, and
          # emptying it would make the reader retype what they just wrote.
          {:noreply,
           socket
           |> assign(:remote_form, remote_form(address))
           |> assign(:follow_error, reason)}
      end
    end)
  end

  # Typing again clears the last refusal, so the box is not still shouting about
  # an address that has since been corrected.
  def handle_event("typing", %{"remote_follow" => %{"address" => address}}, socket) do
    {:noreply,
     socket
     |> assign(:remote_form, remote_form(address))
     |> assign(:follow_error, nil)}
  end

  def handle_event("unfollow-remote", %{"id" => id}, socket) do
    with_publisher(socket, fn organization ->
      Fediverse.unfollow_remote(organization, id)
      {:noreply, load_following(socket)}
    end)
  end

  def handle_event("mute-remote", %{"id" => id}, socket),
    do: set_remote_mute(socket, id, true)

  def handle_event("unmute-remote", %{"id" => id}, socket),
    do: set_remote_mute(socket, id, false)

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp follow_local(socket, organization, account) do
    case Social.follow_as_organization(organization, account) do
      {:ok, _follow} ->
        {:noreply,
         socket
         |> assign(:local_form, local_form())
         |> assign(:local_follow_error, nil)
         |> load_following()}

      {:error, _reason} ->
        {:noreply, assign(socket, :local_follow_error, :not_found)}
    end
  end

  defp local_account(address) do
    case local_handle(address) do
      {:ok, handle} ->
        account =
          Accounts.get_user_by_username(handle) ||
            Organizations.get_organization_by_username(handle) ||
            Organizations.get_organization_by_slug(handle)

        visible_local_account(account)

      _not_local ->
        nil
    end
  end

  defp local_handle(address) do
    case address |> String.trim() |> String.trim_leading("@") |> String.split("@", parts: 2) do
      [handle] when handle != "" ->
        {:ok, String.downcase(handle)}

      # `client_host?/1`, not a literal list of the two hosts we happen to think
      # of: it also answers for the `www.` alias and normalizes a shouted or
      # fully-qualified host. Without it a pasted `@member@www.<our host>` falls
      # through to `:remote` — the fall-through-to-the-foreign-path failure the
      # project rule was written about.
      [handle, host] when handle != "" ->
        if MastodonApi.client_host?(host),
          do: {:ok, String.downcase(handle)},
          else: :remote

      _invalid ->
        :invalid
    end
  end

  defp visible_local_account(nil), do: nil

  defp visible_local_account(account) do
    if not Vutuv.Identity.hidden?(account), do: account
  end

  defp set_local_mute(socket, follow_id, muted?) do
    with_publisher(socket, fn organization ->
      _ = Social.set_follow_edge_mute_as_organization(organization, follow_id, muted?)
      {:noreply, load_following(socket)}
    end)
  end

  defp set_remote_mute(socket, account_id, muted?) do
    with_publisher(socket, fn organization ->
      :ok = Fediverse.set_remote_follow_mute(organization, account_id, muted?)
      {:noreply, load_following(socket)}
    end)
  end

  defp with_publisher(socket, fun) do
    organization = socket.assigns.organization

    if Organizations.publisher?(organization, socket.assigns.current_user) do
      fun.(organization)
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You are not allowed to change this organization."))
       |> push_navigate(to: "/organizations/#{organization.slug}/activity")}
    end
  end

  # `follow_remote_as_organization/2` speaks the same refusal vocabulary as the
  # member path, so each one gets a sentence rather than an atom on screen.
  defp follow_error_message(:invalid_address),
    do: gettext("That does not look like a Fediverse address.")

  defp follow_error_message(:already_following),
    do: gettext("This page already follows that account.")

  defp follow_error_message(:unreachable_actor),
    do: gettext("That server did not answer.")

  defp follow_error_message(:follow_capped),
    do: gettext("Too many attempts for now. Try again later.")

  defp follow_error_message(:blocked_instance),
    do: gettext("That server is blocked on this installation.")

  # Its own msgid, not the member's "You are following …": a different voice
  # speaks here — the reader acts for the page, they are not the follower.
  defp follow_error_message(:follow_limit),
    do:
      gettext("This page is following the most accounts we allow (%{max}).",
        max: delimited_count(Fediverse.max_remote_follows())
      )

  defp follow_error_message(_other), do: gettext("That did not work.")

  defp local_follow_error_message(:self), do: gettext("An organization cannot follow itself.")

  defp local_follow_error_message(:not_found),
    do: gettext("No visible local account has that handle.")

  defp local_follow_error_message(_other), do: gettext("That did not work.")

  defp local_form(value \\ ""), do: to_form(%{"account" => value}, as: :local_follow)
  defp remote_form(value \\ ""), do: to_form(%{"address" => value}, as: :remote_follow)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header
        organization={@organization}
        active={:following}
        viewer={@current_user}
      />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Follows")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("The members, organizations and topics this page follows. Everything here shapes its feed, and only the team can see this list.")}
      </p>

      <.card class="mt-6" id="organization-follow-local">
        <.section_title>{gettext("Follow a local account")}</.section_title>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Enter a member handle or organization handle. This follow belongs to the organization, not to your personal account.")}
        </p>
        <.form
          for={@local_form}
          id="organization-follow-local-form"
          phx-submit="follow-local"
          phx-change="typing-local"
          class="mt-3 flex flex-wrap gap-2"
        >
          <input
            type="text"
            id={@local_form[:account].id}
            name={@local_form[:account].name}
            value={@local_form[:account].value}
            placeholder="@name"
            autocomplete="off"
            class={[input_class(), "min-w-0 flex-1"]}
            aria-label={gettext("Local account")}
          />
          <.button type="submit">{gettext("Follow")}</.button>
        </.form>
        <p :if={@local_follow_error} class="editform__error mt-2" role="alert">
          {local_follow_error_message(@local_follow_error)}
        </p>
      </.card>

      <.card class="mt-4" id="organization-followees">
        <.section_title>{gettext("Members and organizations")}</.section_title>

        <p :if={@followees == []} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("This page does not follow anyone yet.")}
        </p>

        <ul :if={@followees != []} class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={{follow, followee} <- @followees} class="flex items-center gap-4 py-4">
            <.link navigate={Posts.author_path(followee)} class="shrink-0">
              <.organization_logo
                :if={match?(%Organization{}, followee)}
                organization={followee}
                class="h-12 w-12"
              />
              <.avatar :if={match?(%User{}, followee)} user={followee} size="md" shape="circle" />
            </.link>

            <div class="min-w-0 flex-1">
              <.link
                navigate={Posts.author_path(followee)}
                class="block truncate font-semibold text-slate-900 hover:text-brand-700 dark:text-slate-100 dark:hover:text-brand-300"
              >
                {author_name(followee)}
              </.link>
              <.organization_location
                :if={match?(%Organization{}, followee)}
                organization={followee}
                class="truncate text-sm text-slate-600 dark:text-slate-400"
              />
            </div>

            <div class="flex shrink-0 gap-2">
              <.button
                variant="secondary"
                phx-click={if follow.muted, do: "unmute", else: "mute"}
                phx-value-id={follow.id}
              >
                {if follow.muted, do: gettext("Unmute"), else: gettext("Mute")}
              </.button>
              <.button
                variant="secondary"
                phx-click="unfollow"
                phx-value-id={follow.id}
              >
                {gettext("Unfollow")}
              </.button>
            </div>
          </li>
        </ul>
      </.card>

      <%!-- Only while the page federates: without that there is no actor to sign
      a Follow with, so the box could not do anything but refuse. --%>
      <.card :if={@federated?} class="mt-4" id="organization-remote-follows">
        <.section_title>{gettext("Accounts on other networks")}</.section_title>

        <.form
          for={@remote_form}
          id="organization-follow-remote-form"
          phx-submit="follow-remote"
          phx-change="typing"
          class="mt-3 flex flex-wrap gap-2"
        >
          <input
            type="text"
            id={@remote_form[:address].id}
            name={@remote_form[:address].name}
            value={@remote_form[:address].value}
            placeholder="@name@server.example"
            autocomplete="off"
            class={[input_class(), "min-w-0 flex-1"]}
            aria-label={gettext("Fediverse address")}
          />
          <.button type="submit">{gettext("Follow")}</.button>
        </.form>

        <p :if={@follow_error} class="editform__error mt-2" role="alert">
          {follow_error_message(@follow_error)}
        </p>

        <p :if={@remote_follows == []} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
          {gettext("This page does not follow anyone on another network yet.")}
        </p>

        <ul :if={@remote_follows != []} class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={follow <- @remote_follows} class="flex items-center gap-4 py-3">
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-semibold text-slate-900 dark:text-slate-100">
                {RemoteAccount.display_name(follow.remote_account) ||
                  follow.remote_account.handle}
              </p>
              <p class="truncate text-sm text-slate-600 dark:text-slate-400">
                {follow.remote_account.handle}
              </p>
            </div>

            <%!-- "Requested" is the truth until the other server answers, and
            an account that approves by hand may never do so. Showing
            "Following" for an unanswered request would be a lie. --%>
            <span
              :if={follow.state == "requested"}
              class="shrink-0 rounded-full bg-slate-100 px-2.5 py-0.5 text-xs font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-200"
            >
              {gettext("Requested")}
            </span>

            <div class="flex shrink-0 gap-2">
              <.button
                variant="secondary"
                phx-click={if follow.muted, do: "unmute-remote", else: "mute-remote"}
                phx-value-id={follow.remote_account.id}
              >
                {if follow.muted, do: gettext("Unmute"), else: gettext("Mute")}
              </.button>
              <.button
                variant="secondary"
                phx-click="unfollow-remote"
                phx-value-id={follow.id}
              >
                {gettext("Unfollow")}
              </.button>
            </div>
          </li>
        </ul>
      </.card>

      <.card class="mt-4" id="organization-followed-tags">
        <.section_title>{gettext("Topics")}</.section_title>

        <p :if={@tags == []} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("This page does not follow any topics yet.")}
        </p>

        <div :if={@tags != []} class="mt-3 flex flex-wrap gap-2">
          <span :for={tag <- @tags} class="inline-flex items-center gap-1">
            <.chip navigate={~p"/tags/#{tag.slug}"}>{tag.name}</.chip>
            <button
              type="button"
              phx-click="unfollow-tag"
              phx-value-id={tag.id}
              title={gettext("Unfollow %{tag}", tag: tag.name)}
              aria-label={gettext("Unfollow %{tag}", tag: tag.name)}
              class="inline-flex h-10 w-10 items-center justify-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-rose-700 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-rose-300"
            >
              ✕
            </button>
          </span>
        </div>
      </.card>
    </div>
    """
  end
end
