defmodule VutuvWeb.FediverseFollowersLive do
  @moduledoc """
  The member's own remote-follower browser (`/settings/fediverse/followers`).

  `/settings/fediverse` answers "do I take part at all"; this page answers "who
  are these people". It used to be a flat list of the 50 most recent rows on
  that page, which reads fine at four followers and not at all at ten thousand:
  no way to look someone up, no way to see when they arrived, no way past the
  first fifty. So the full list is its own page and its own **table**: search as
  you type (display name, handle, server, or a whole `@user@server` handle
  pasted out of a Mastodon profile), a server filter, three sortable columns
  (Account / Server / Following since) and numbered paging.

  Filter, sort and page live in the **URL** (`push_patch`), so a particular view
  is shareable and the back button restores it; `handle_params/3` is the single
  loader, the table itself — query string, sortable headers, filter form,
  account and server cells, range line and pager — is `VutuvWeb.BrowseTable`
  (shared with the mirror-image following browser) and the query work stays in
  `Vutuv.Fediverse` (`browse_filters/1`, `count_followers/2`,
  `list_followers_page/4`, `follower_hosts/2`). What is left here is what
  genuinely differs: the rows, the columns, and the wording.

  Owner-only by construction: it lives in the `/settings` scope, reads only
  `current_user`'s rows, and a member who does not federate is sent back to
  `/settings/fediverse`, where the switch is.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.BrowseTable

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Pages

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if Fediverse.federated?(user) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Followers from other networks"))
       |> assign(:user, user)
       |> assign(:total_followers, Fediverse.follower_count(user))
       |> assign(:hosts, Fediverse.follower_hosts(user))}
    else
      {:ok, push_navigate(socket, to: ~p"/settings/fediverse")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.user
    filters = Fediverse.browse_filters(params)
    per_page = Fediverse.browse_per_page()
    total = Fediverse.count_followers(user, filters)
    page = Pages.effective_page(params, total, per_page)

    followers =
      Fediverse.list_followers_page(user, filters, %{"page" => page},
        total: total,
        per_page: per_page
      )

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:total, total)
     |> assign(:page, page)
     |> assign(:per_page, per_page)
     |> assign(:followers, followers)}
  end

  # ── Events (every one just rewrites the URL; handle_params reloads) ──

  @impl true
  # Replaced, not pushed: the search box fires per burst of typing, and on a
  # phone the back gesture is the way out of a page. Pushing would make leaving
  # take one press per search term.
  def handle_event("filter", params, socket) do
    {:noreply, patch(socket, %{"q" => params["q"], "server" => params["server"]}, replace: true)}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    {:noreply, patch(socket, %{"sort" => col, "dir" => next_dir(socket.assigns.filters, col)})}
  end

  # A server name in a row is a filter you can click: at ten thousand followers
  # "show me everyone else from this server" is the question the list raises.
  def handle_event("filter_server", %{"host" => host}, socket) do
    {:noreply, patch(socket, %{"server" => host})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/settings/fediverse/followers")}
  end

  # The current view with `overrides` applied, as a URL.
  defp patch(socket, overrides, opts \\ []) do
    query = build_query(socket.assigns.filters, overrides)
    push_patch(socket, [to: ~p"/settings/fediverse/followers?#{query}"] ++ opts)
  end

  # The three columns. The Server column folds away below `sm`
  # (`phone_hidden_class/0`), so the two facts a phone reader came for - who,
  # and since when - both fit without a sideways scroll.
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
    <.settings_shell
      user={@user}
      active={:fediverse}
      title={gettext("Followers from other networks")}
      crumbs={[
        {gettext("Settings"), ~p"/settings"},
        {gettext("Fediverse"), ~p"/settings/fediverse"},
        gettext("Followers")
      ]}
    >
      <div class="space-y-6">
        <.card>
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <.section_title>{gettext("Followers from other networks")}</.section_title>
            <span
              id="follower-total"
              class="rounded-full bg-slate-100 px-2 py-0.5 text-sm font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300"
            >
              {delimited_count(@total_followers)}
            </span>
          </div>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Everyone on another network who follows your vutuv posts. Only you see this list: the followers collection your profile publishes carries the number, never the names."
            )}
          </p>

          <%= if @total_followers == 0 do %>
            <p class="mt-4 text-sm text-slate-600 dark:text-slate-400" id="no-followers">
              {gettext(
                "Nobody yet. Post your handle where people can see it, and the first follows will show up here."
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
                        name={follower.name}
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
                        format="%Y-%m-%d"
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <.browse_footer
              :if={@followers != []}
              page={@page}
              per_page={@per_page}
              total={@total}
              path={~p"/settings/fediverse/followers"}
              filters={@filters}
            />
          <% end %>
        </.card>

        <.card>
          <.section_title>{gettext("How this list keeps itself honest")}</.section_title>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Accounts that no longer exist on their own server drop off this list by themselves. Names and handles are the ones their server last told us, so a renamed account updates here on its own too."
            )}
          </p>
          <.card_footer_link href={~p"/settings/fediverse"}>
            {gettext("Back to Fediverse settings")}
          </.card_footer_link>
        </.card>
      </div>
    </.settings_shell>
    """
  end
end
