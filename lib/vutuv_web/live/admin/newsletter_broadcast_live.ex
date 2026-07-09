defmodule VutuvWeb.Admin.NewsletterBroadcastLive do
  @moduledoc """
  The newsletter send flow: pick an audience, confirm in a "Are you sure?" modal
  that states how many people it reaches, then watch a live progress view as the
  emails go out (the background broadcast inserts one delivery row per recipient;
  this polls the count while the newsletter is `sending`).

  Lives in the `:admin` live_session (`on_mount :require_admin`).
  """

  use VutuvWeb, :live_view

  alias Vutuv.Newsletters

  @tick_ms 1000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Newsletters.get_newsletter(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That newsletter could not be found."))
         |> push_navigate(to: ~p"/admin/newsletters")}

      newsletter ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Send newsletter"))
         |> assign(:newsletter, newsletter)
         |> assign(:groups, Newsletters.list_groups())
         |> assign(:selected_group_id, "")
         |> assign(:confirming?, false)
         |> assign(:confirm_count, 0)
         |> assign(:reach, Newsletters.broadcast_reach(nil))
         |> assign_progress()
         |> maybe_tick()}
    end
  end

  @impl true
  def handle_event("select_audience", %{"group_id" => group_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_group_id, group_id)
     |> assign(:reach, Newsletters.broadcast_reach(blank_nil(group_id)))}
  end

  def handle_event("confirm", _params, socket) do
    count = Newsletters.broadcast_reach(blank_nil(socket.assigns.selected_group_id))
    {:noreply, socket |> assign(:confirming?, true) |> assign(:confirm_count, count)}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :confirming?, false)}

  def handle_event("send", _params, socket) do
    newsletter = socket.assigns.newsletter
    group_id = blank_nil(socket.assigns.selected_group_id)

    case Newsletters.start_broadcast(newsletter, group_id) do
      {:ok, :started} ->
        {:noreply,
         socket
         |> assign(:newsletter, Newsletters.get_newsletter!(newsletter.id))
         |> assign(:confirming?, false)
         |> assign_progress()
         |> maybe_tick()}

      {:error, :already_sent} ->
        {:noreply,
         socket
         |> assign(:confirming?, false)
         |> put_flash(:error, gettext("This newsletter has already been sent."))}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply,
     socket
     |> assign(:newsletter, Newsletters.get_newsletter!(socket.assigns.newsletter.id))
     |> assign_progress()
     |> maybe_tick()}
  end

  # In tests `:async_email` is false, so the broadcast runs inline in this
  # process and the Swoosh test adapter delivers `{:email, _}` back to us;
  # ignore it (and any other stray message), like every other live view here.
  def handle_info(_other, socket), do: {:noreply, socket}

  # While the send runs in the background, poll the delivery count once a second
  # so the progress view updates on its own.
  defp maybe_tick(socket) do
    if connected?(socket) and socket.assigns.newsletter.status == "sending" do
      Process.send_after(self(), :tick, @tick_ms)
    end

    socket
  end

  defp assign_progress(socket) do
    newsletter = socket.assigns.newsletter
    sent = Newsletters.broadcast_sent_count(newsletter)

    total =
      if newsletter.status == "sent",
        do: newsletter.recipient_count,
        else: Newsletters.broadcast_reach(newsletter.group_id)

    socket |> assign(:sent_so_far, sent) |> assign(:total, total)
  end

  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value), do: value

  defp percent(sent, total) when is_integer(total) and total > 0,
    do: min(round(sent / total * 100), 100)

  defp percent(_sent, _total), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={@newsletter.subject}
      crumbs={[
        {gettext("Admin"), ~p"/admin"},
        {gettext("Newsletters"), ~p"/admin/newsletters"},
        {@newsletter.subject, ~p"/admin/newsletters/#{@newsletter}"},
        gettext("Send")
      ]}
    />

    <div class="card-list">
      <section class="card">
        <%= case @newsletter.status do %>
          <% "draft" -> %>
            <h1>{gettext("Send newsletter")}</h1>
            <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
              {gettext("Pick an audience, confirm, and watch it go out.")}
            </p>

            <form phx-change="select_audience" id="audience-form" class="mt-4">
              <label for="audience" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
                {gettext("Recipient group")}
              </label>
              <select name="group_id" id="audience" class={input_class()}>
                <option value="" selected={@selected_group_id in [nil, ""]}>
                  {gettext("All eligible members")}
                </option>
                <option :for={g <- @groups} value={g.id} selected={g.id == @selected_group_id}>
                  {g.name} ({compact_count(g.member_count)})
                </option>
              </select>
            </form>

            <p class="mt-3 text-sm text-slate-700 dark:text-slate-200">
              {gettext("This selection reaches")}
              <strong id="reach-count">{delimited_count(@reach)}</strong> {ngettext("member.", "members.", @reach)}
            </p>

            <div class="mt-4">
              <.button variant="danger" phx-click="confirm" id="open-confirm">
                {gettext("Send newsletter")}
              </.button>
            </div>
          <% "sending" -> %>
            <h1>{gettext("Sending…")}</h1>
            {progress(assigns)}
            <p class="mt-2 text-xs text-slate-600 dark:text-slate-400">
              {gettext("This updates on its own. You can leave this page; the send keeps running.")}
            </p>
          <% _ -> %>
            <h1>{gettext("Done")}</h1>
            <p class="mt-1 text-sm text-slate-700 dark:text-slate-200">
              {ngettext("Sent to %{formatted} member.", "Sent to %{formatted} members.",
                @newsletter.recipient_count,
                formatted: delimited_count(@newsletter.recipient_count)
              )}
            </p>
            {progress(assigns)}
            <div class="mt-4">
              <.link
                navigate={~p"/admin/newsletters/#{@newsletter}"}
                class="text-sm font-semibold text-brand-600 hover:text-brand-700"
              >
                {gettext("View the delivery log")} ›
              </.link>
            </div>
        <% end %>
      </section>
    </div>

    <div
      :if={@confirming?}
      class="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4"
      id="confirm-modal"
    >
      <div class="w-full max-w-md rounded-2xl bg-white p-6 shadow-xl ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800">
        <h2 class="text-lg font-bold text-slate-900 dark:text-white">{gettext("Are you sure?")}</h2>
        <p class="mt-2 text-sm text-slate-700 dark:text-slate-200">
          {ngettext(
            "The newsletter will be sent to %{formatted} person. This cannot be undone.",
            "The newsletter will be sent to %{formatted} people. This cannot be undone.",
            @confirm_count,
            formatted: delimited_count(@confirm_count)
          )}
        </p>
        <div class="mt-6 flex items-center justify-end gap-3">
          <button
            type="button"
            phx-click="cancel"
            class="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
          >
            {gettext("Cancel")}
          </button>
          <.button variant="danger" phx-click="send" id="confirm-send">
            {gettext("Send now")}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp progress(assigns) do
    assigns = assign(assigns, :percent, percent(assigns.sent_so_far, assigns.total))

    ~H"""
    <div class="mt-3">
      <p class="text-sm text-slate-700 dark:text-slate-200">
        {gettext("%{sent} of %{total} emails sent",
          sent: delimited_count(@sent_so_far),
          total: delimited_count(@total)
        )}
      </p>
      <div class="mt-2 h-3 w-full overflow-hidden rounded-full bg-slate-200 dark:bg-slate-700">
        <div class="h-full rounded-full bg-brand-600 transition-all" style={"width:#{@percent}%"}></div>
      </div>
    </div>
    """
  end
end
