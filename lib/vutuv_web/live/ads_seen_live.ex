defmodule VutuvWeb.AdsSeenLive do
  @moduledoc """
  The ads vutuv showed a member, at `/system/ads/seen`: the page the ad card's
  "Ad" label leads a member to (`VutuvWeb.AdComponents`).

  One entry per booked ad they saw, the most recently seen first, each the ad
  itself with when it was last seen and how often (`Vutuv.Ads.seen_ads/2`,
  kept #{Vutuv.Ads.sighting_days()} days). A search over the ad text narrows
  the list, and "Load more" pages through the rest. Login only: a visitor has
  no history, and the label sends them to the `/ads` offer page instead.
  """

  use VutuvWeb, :live_view

  alias Vutuv.Ads
  alias Vutuv.SearchText
  alias VutuvWeb.AdComponents
  alias VutuvWeb.Live.InitAssigns

  on_mount({InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    # The router's pipeline already 404s a request while ads are off; this
    # covers a live navigation, which skips the pipeline.
    if Ads.enabled?() do
      {:ok, socket |> assign(:page_title, gettext("Ads you have seen")) |> search(nil)}
    else
      {:ok, InitAssigns.not_found(socket)}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    query = q |> SearchText.cap() |> SearchText.normalize_search()

    # Enter after the debounced change, or a trailing space, asks nothing new.
    if query == socket.assigns.query,
      do: {:noreply, socket},
      else: {:noreply, search(socket, query)}
  end

  def handle_event("load-more", _params, socket), do: {:noreply, load(socket)}

  # `query` is nil or a trimmed term; a new one starts the list over.
  defp search(socket, query), do: socket |> assign(query: query, last: nil) |> load()

  # The page after `last`, or the first page when there is none yet.
  defp load(socket) do
    %{current_user: user, query: query, last: last} = socket.assigns
    {rows, more?} = Ads.seen_ads(user, query: query, after: last)
    first_page? = is_nil(last)

    socket =
      socket
      |> stream(:sightings, rows, reset: first_page?)
      |> assign(more?: more?)
      |> assign(:last, cursor(List.last(rows)) || last)

    cond do
      not first_page? -> socket
      more? -> assign(socket, :total, Ads.count_seen_ads(user, query))
      true -> assign(socket, :total, length(rows))
    end
  end

  defp cursor(nil), do: nil
  defp cursor(sighting), do: Map.take(sighting, [:last_seen_at, :id])

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-6 py-6">
      <header class="space-y-2">
        <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">
          {gettext("Ads you have seen")}
        </h1>
        <p class="mb-0 text-slate-700 dark:text-slate-300">
          {gettext("Every ad vutuv showed you in the last %{days} days, the most recent first.",
            days: Ads.sighting_days()
          )}
        </p>
        <p class="mb-0 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "You see at most one ad an hour, and none for the rest of the day once you close one."
          )}
        </p>
      </header>

      <form
        :if={@total > 0 or @query != nil}
        id="ads-seen-search"
        role="search"
        phx-change="search"
        phx-submit="search"
      >
        <label for="ads-seen-q" class="sr-only">{gettext("Search the ads you have seen")}</label>
        <input
          id="ads-seen-q"
          type="search"
          name="q"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          placeholder={gettext("Search the ads you have seen")}
          class={input_class()}
        />
      </form>

      <p :if={@total > 0} id="ads-seen-count" class="mb-0 text-sm text-slate-600 dark:text-slate-400">
        {count_line(@total, @query)}
      </p>

      <.card :if={@total == 0 and @query == nil} id="ads-seen-empty">
        <p class="mb-0 text-slate-700 dark:text-slate-300">
          {gettext("You have not seen an ad in the last %{days} days.", days: Ads.sighting_days())}
          <.link
            href={~p"/ads"}
            class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
          >
            {gettext("How ads work on vutuv")}
          </.link>
        </p>
      </.card>

      <p :if={@total == 0 and @query != nil} class="mb-0 text-slate-700 dark:text-slate-300">
        {gettext("No ad you have seen matches “%{query}”.", query: @query)}
      </p>

      <div id="ads-seen" phx-update="stream" class="space-y-4">
        <article :for={{dom_id, sighting} <- @streams.sightings} id={dom_id}>
          <AdComponents.ad_card id={"#{dom_id}-ad"} banner={{:ad, sighting.ad}}>
            <:footer>
              <%!-- The `m-0` and `font-normal` undo the legacy `dt`/`dd` rules
                    in `components.css`. --%>
              <dl class="mb-0 mt-3 flex flex-wrap gap-x-6 gap-y-1 border-t border-slate-100 pt-3 text-sm dark:border-slate-800">
                <div class="flex gap-1.5">
                  <dt class="m-0 text-slate-600 dark:text-slate-400">{gettext("Last seen")}</dt>
                  <dd class="m-0 font-normal text-slate-900 dark:text-slate-100">
                    <.local_time at={sighting.last_seen_at} id={"#{dom_id}-seen"} />
                  </dd>
                </div>
                <div class="flex gap-1.5">
                  <dt class="m-0 text-slate-600 dark:text-slate-400">{gettext("How often")}</dt>
                  <dd class="m-0 font-normal text-slate-900 dark:text-slate-100">
                    {ngettext("once", "%{count} times", sighting.times_seen)}
                  </dd>
                </div>
              </dl>
            </:footer>
          </AdComponents.ad_card>
        </article>
      </div>

      <.load_more :if={@more?} />
    </div>
    """
  end

  defp count_line(total, query) do
    formatted = delimited_count(total)

    if query,
      do: ngettext("%{formatted} match", "%{formatted} matches", total, formatted: formatted),
      else: ngettext("%{formatted} ad", "%{formatted} ads", total, formatted: formatted)
  end
end
