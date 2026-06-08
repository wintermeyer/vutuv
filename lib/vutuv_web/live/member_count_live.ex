defmodule VutuvWeb.MemberCountLive do
  @moduledoc """
  The "Number of Members" pill on the logged-out landing page, as a tiny
  embedded LiveView so the exact total ticks up live as people register.

  Embedded via `live_render` in `page/index.html.heex` (like `ShellLive` in the
  app layout), so it gets its own socket even on the otherwise-dead sign-up
  page. The disconnected mount renders the seeded total immediately; once the
  socket joins it subscribes to `Vutuv.Accounts.MemberCounter` and re-renders on
  each coalesced `{:member_count, n}` broadcast.

  Uses `Phoenix.LiveView` directly (no app layout) so it does not pull in the
  page chrome around a single pill.
  """
  use Phoenix.LiveView

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [delimited_count: 1]

  alias Vutuv.Accounts.MemberCounter

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: MemberCounter.subscribe()

    # Embedded outside the live_session, so re-apply the request locale (the pill
    # copy is gettext) the same way ShellLive does.
    VutuvWeb.LiveLocale.put_locale(session)

    {:ok, assign(socket, :count, MemberCounter.count())}
  end

  @impl true
  def handle_info({:member_count, count}, socket),
    do: {:noreply, assign(socket, :count, count)}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <p
      id="member-count"
      class="mt-6 inline-flex items-center gap-2 rounded-full bg-white/15 px-4 py-1.5 text-sm font-semibold text-white backdrop-blur"
    >
      {gettext("Number of Members")}:
      <span class="tabular-nums">{delimited_count(@count)}</span>
    </p>
    """
  end
end
