defmodule VutuvWeb.JobPostingLive.Dashboard do
  @moduledoc """
  The poster's dashboard (`/jobs/mine`, issue #932): the member's own postings by
  status (Drafts / Active / Expired / Closed), each with its view and
  apply-click counts, inline close / edit and a one-tap repost for expired
  postings. A member who never posts a job never sees this page.
  """

  use VutuvWeb, :live_view

  alias Vutuv.Jobs

  @tabs [
    {:published, "Active"},
    {:draft, "Drafts"},
    {:expired, "Expired"},
    {:closed, "Closed"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Please log in to see your postings."))
         |> push_navigate(to: ~p"/login")}

      _user ->
        {:ok, assign(socket, :page_title, gettext("My postings"))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = parse_tab(params["tab"])

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:counts, Jobs.own_status_counts(socket.assigns.current_user))
     |> load_page(tab, 0, [])}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    {:noreply,
     load_page(socket, socket.assigns.tab, socket.assigns.offset, socket.assigns.postings)}
  end

  def handle_event("close", %{"id" => id, "reason" => reason}, socket) do
    posting = own_posting(socket, id)

    if posting do
      {:ok, _} = Jobs.close(posting, String.to_existing_atom(reason))
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("repost", %{"id" => id}, socket) do
    posting = own_posting(socket, id)

    case posting && Jobs.repost(posting, socket.assigns.current_user) do
      {:ok, draft} -> {:noreply, push_navigate(socket, to: ~p"/jobs/#{draft.slug}/edit")}
      _ -> {:noreply, socket}
    end
  end

  defp own_posting(socket, id) do
    case Jobs.get_job_posting(id) do
      nil -> nil
      posting -> if Jobs.owner?(posting, socket.assigns.current_user), do: posting
    end
  end

  defp refresh(socket) do
    socket
    |> assign(:counts, Jobs.own_status_counts(socket.assigns.current_user))
    |> load_page(socket.assigns.tab, 0, [])
  end

  defp load_page(socket, tab, offset, acc) do
    page = Jobs.list_own_postings(socket.assigns.current_user, tab, offset: offset)

    socket
    |> assign(:postings, acc ++ page.entries)
    |> assign(:more?, page.more?)
    |> assign(:offset, page.next_offset)
  end

  # Match known values only (never `to_existing_atom` arbitrary input).
  defp parse_tab(value) when value in ~w(published draft expired closed),
    do: String.to_existing_atom(value)

  defp parse_tab(_value), do: :published

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="py-6">
      <div class="mb-6 flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("My postings")}</h1>
        <.link navigate={~p"/jobs/new"} class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700">
          {gettext("New posting")}
        </.link>
      </div>

      <nav class="mb-4 flex flex-wrap gap-2 border-b border-slate-200 pb-2 dark:border-slate-800">
        <.link
          :for={{status, label} <- @tabs}
          patch={~p"/jobs/mine?#{[tab: status]}"}
          class={[
            "rounded-lg px-3 py-1.5 text-sm font-medium",
            if(@tab == status,
              do: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100",
              else: "text-slate-600 hover:text-slate-800 dark:text-slate-400"
            )
          ]}
        >
          {tab_label(label)} <span class="tabular-nums">{compact_count(Map.get(@counts, status, 0))}</span>
        </.link>
      </nav>

      <div :if={@postings == []} class="rounded-2xl bg-white p-6 text-sm text-slate-600 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-400 dark:ring-slate-800">
        {gettext("Nothing here yet.")}
      </div>

      <ul class="space-y-3">
        <li
          :for={posting <- @postings}
          class="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <.link navigate={~p"/jobs/#{posting.slug}"} class="font-semibold text-slate-900 hover:text-brand-700 dark:text-slate-100">
                {posting.title}
              </.link>
              <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
                {gettext("%{views} views · %{clicks} apply clicks",
                  views: compact_count(posting.view_count),
                  clicks: compact_count(posting.apply_click_count))}
                <span :if={@tab == :published and not is_nil(posting.expires_on)}>
                  · {gettext("Expires")}: {Calendar.strftime(posting.expires_on, "%Y-%m-%d")}
                </span>
              </p>
            </div>

            <div class="flex flex-wrap gap-2 text-sm">
              <.link navigate={~p"/jobs/#{posting.slug}/edit"} class="font-semibold text-brand-600 hover:text-brand-700">
                {gettext("Edit")}
              </.link>
              <button
                :if={@tab == :published}
                type="button"
                phx-click="close"
                phx-value-id={posting.id}
                phx-value-reason="filled"
                data-confirm={gettext("Mark this posting as filled and close it?")}
                class="font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400"
              >
                {gettext("Mark as filled")}
              </button>
              <button
                :if={@tab in [:expired, :closed]}
                type="button"
                phx-click="repost"
                phx-value-id={posting.id}
                class="font-semibold text-brand-600 hover:text-brand-700"
              >
                {gettext("Repost")}
              </button>
            </div>
          </div>
        </li>
      </ul>

      <.load_more :if={@more?} class="mt-6" />
    </div>
    """
  end

  # Tab labels come from the module attribute (English source), translated here.
  defp tab_label("Active"), do: gettext("Active")
  defp tab_label("Drafts"), do: gettext("Drafts")
  defp tab_label("Expired"), do: gettext("Expired")
  defp tab_label("Closed"), do: gettext("Closed")
end
