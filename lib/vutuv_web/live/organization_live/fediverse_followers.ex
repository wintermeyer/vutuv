defmodule VutuvWeb.OrganizationLive.FediverseFollowers do
  @moduledoc """
  Who follows a page from other networks
  (`/organizations/:slug/fediverse/followers`).

  The Fediverse card beside it knew the number and not one name — "0 accounts
  there follow it" was everything a team could learn about the reach it had just
  switched on. `Fediverse.list_organization_followers/2` had been sitting there
  unread since #1334; this is the page that reads it.

  **Owner-only, like the Fediverse tab it hangs off.** These are names of people
  who never signed up here, and the page's own followers collection publishes
  the count and never the names, so the list stays with the member who decided
  to federate in the first place. Widening it to the whole team later is one
  line; taking it back would not be.

  It reuses `VutuvWeb.BrowseTable` — the same search, server filter and sortable
  columns the member's `/settings/fediverse/followers` wears — with **one
  difference that is structural, not a choice**: this LiveView is embedded by
  `VutuvWeb.OrganizationController` through `live_render`, like every other
  organization manage page, and an embedded LiveView is not mounted at the
  router, so `push_patch/2` and `handle_params/3` are not available to it. The
  member's page keeps its view in the URL; this one keeps it in the socket and
  pages with `<.admin_pager>` (`phx-click`), the way the admin oversight tables
  do. So a filtered view here is not a shareable link, and that is the whole
  cost.

  No live updates either: a follow from another network arrives at the page's
  inbox and nothing broadcasts it, so the list is as fresh as the last load —
  which is why nothing on it promises otherwise.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.BrowseTable
  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:page_title, gettext("Followers – %{name}", name: organization.name))
     |> assign(:organization, organization)
     |> assign(:filters, Fediverse.browse_filters(%{}))
     |> assign(:page, 1)
     |> assign_totals()
     |> load_page()}
  end

  # The headline count and the server dropdown describe the whole list, whatever
  # the current view filters out of it, so they are read once per mount.
  defp assign_totals(socket) do
    organization = socket.assigns.organization

    socket
    |> assign(:total_followers, Fediverse.organization_remote_follower_count(organization))
    |> assign(:hosts, Fediverse.follower_hosts(organization))
  end

  defp load_page(socket) do
    organization = socket.assigns.organization
    filters = socket.assigns.filters
    per_page = Fediverse.browse_per_page()
    total = Fediverse.count_followers(organization, filters)
    pages = max(div(total + per_page - 1, per_page), 1)
    page = socket.assigns.page |> min(pages) |> max(1)

    followers =
      Fediverse.list_followers_page(organization, filters, %{"page" => page},
        total: total,
        per_page: per_page
      )

    socket
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:pages, pages)
    |> assign(:followers, followers)
  end

  # Every filter change goes back through `Fediverse.browse_filters/1`, the same
  # validation the URL-driven page uses, so a bad value cannot reach the query
  # from here either.
  defp apply_filters(socket, overrides) do
    current = socket.assigns.filters

    params = %{
      "q" => Map.get(overrides, "q", current.q),
      "server" => Map.get(overrides, "server", current.server),
      "sort" => Map.get(overrides, "sort", current.sort),
      "dir" => Map.get(overrides, "dir", current.dir)
    }

    socket
    |> assign(:filters, Fediverse.browse_filters(params))
    |> assign(:page, 1)
    |> load_page()
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, apply_filters(socket, %{"q" => params["q"], "server" => params["server"]})}
  end

  def handle_event("filter_server", %{"host" => host}, socket) do
    {:noreply, apply_filters(socket, %{"server" => host})}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    dir = next_dir(socket.assigns.filters, fediverse_config(), col)

    {:noreply, apply_filters(socket, %{"sort" => col, "dir" => dir})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, Fediverse.browse_filters(%{}))
     |> assign(:page, 1)
     |> load_page()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, String.to_integer(page)) |> load_page()}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # The Server column folds away below `sm`, so the two facts a phone reader
  # came for — who, and since when — both fit without a sideways scroll.
  defp columns do
    [
      {"account", gettext("Account"), nil},
      {"server", gettext("Server"), phone_hidden_class()},
      {"followed", gettext("Following since"), nil}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header
        organization={@organization}
        active={:fediverse}
        viewer={@current_user}
      />

      <div class="space-y-6">
        <.card>
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <.section_title>{gettext("Followers from other networks")}</.section_title>
            <.count_pill id="follower-total" count={@total_followers} />
          </div>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Everyone on another network who follows this page. Only you see this list: what the page publishes out there is the number, never the names."
            )}
          </p>

          <%= if @total_followers == 0 do %>
            <p class="mt-4 text-sm text-slate-600 dark:text-slate-400" id="no-followers">
              {gettext(
                "Nobody yet. Post the page's address where people can see it, and the first follows will show up here."
              )}
            </p>
          <% else %>
            <.filter_form id="follower-filter" filters={@filters} hosts={@hosts} class="mt-4" />

            <p
              :if={@followers == []}
              class="mt-4 text-sm text-slate-600 dark:text-slate-400"
              id="no-matches"
            >
              {gettext("No follower matches that. Try a shorter search, or clear the filters.")}
            </p>

            <div :if={@followers != []} class="card__tablewrap mt-4">
              <table class="pure-table">
                <thead>
                  <tr>
                    <.sort_header
                      :for={{col, label, class} <- columns()}
                      col={col}
                      label={label}
                      class={class}
                      filters={@filters}
                    />
                  </tr>
                </thead>
                <tbody id="followers">
                  <tr :for={follower <- @followers} id={"follower-#{follower.id}"}>
                    <td>
                      <.account_link
                        uri={follower.actor_uri}
                        name={Follower.display_name(follower)}
                        handle={Follower.display_handle(follower)}
                      />
                    </td>
                    <td class={phone_hidden_class()}>
                      <.server_filter
                        host={Follower.host(follower)}
                        title={gettext("Show only followers from this server")}
                      />
                    </td>
                    <td class="whitespace-nowrap text-slate-600 dark:text-slate-400">
                      <.local_time
                        at={follower.inserted_at}
                        id={"followed-#{follower.id}"}
                        style={:date}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <.admin_pager
              :if={@followers != []}
              page={@page}
              pages={@pages}
              prev_id="prev-page"
              next_id="next-page"
            />
          <% end %>
        </.card>

        <.card>
          <.section_title>{gettext("How this list keeps itself honest")}</.section_title>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Accounts that no longer exist on their own server drop off this list by themselves. Names and handles are the ones their server last told us."
            )}
          </p>
          <.card_footer_link href={~p"/organizations/#{@organization.slug}/fediverse"}>
            {gettext("Back to the Fediverse page")}
          </.card_footer_link>
        </.card>
      </div>
    </div>
    """
  end
end
