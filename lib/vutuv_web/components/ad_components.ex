defmodule VutuvWeb.AdComponents do
  @moduledoc """
  The daily text ad as a card: what a profile and the feed carry (see
  `VutuvWeb.AdServing` and `VutuvWeb.Live.AdSlot`) and what the booking
  preview shows the buyer.
  """

  use VutuvWeb, :html

  alias Phoenix.LiveView.JS
  alias Vutuv.Ads

  @doc """
  The live card in one of its two places on a page, or nothing while the page
  has no ad. A page carries both: `:rail` leads the desktop rail, `:inline`
  stands near the top of the one column a phone has.
  """
  attr(:banner, :any, required: true)
  attr(:placement, :atom, required: true, values: [:rail, :inline])

  def ad_slot(assigns) do
    ~H"""
    <.ad_card
      :if={@banner}
      id={"ad-slot-#{@placement}"}
      class={if @placement == :rail, do: "hidden md:block", else: "md:hidden"}
      banner={@banner}
      dismissible
    />
    """
  end

  @doc """
  The ad card: the unmistakable label, then the booked ad's Markdown
  (`{:ad, ad}`) or the house ad (`:house`) that sells the slot.

  `dismissible` is the live card: it adds the ✕ (`"dismiss-ad"`), the
  `AdSlot` hook that keeps a closed day in the browser, and a fade when the
  card leaves. The booking preview leaves all three off.
  """
  attr(:id, :string, required: true)
  attr(:banner, :any, required: true)
  attr(:dismissible, :boolean, default: false)
  attr(:class, :any, default: nil)

  def ad_card(assigns) do
    ~H"""
    <aside
      id={@id}
      aria-label={gettext("Ad")}
      phx-hook={@dismissible && "AdSlot"}
      phx-remove={@dismissible && fade_out()}
      data-ad-day={@dismissible && Date.to_iso8601(Ads.today())}
      class={[
        "rounded-2xl bg-white px-6 py-5 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800",
        @class
      ]}
    >
      <div class="flex items-center gap-3">
        <span class="rounded border border-slate-300 px-1 text-[10px] font-semibold uppercase tracking-wide text-slate-600 dark:border-slate-600 dark:text-slate-400">{gettext("Ad")}</span>
        <button
          :if={@dismissible}
          type="button"
          phx-click="dismiss-ad"
          data-ad-dismiss
          aria-label={gettext("Hide ads for today")}
          title={gettext("Hide ads for today")}
          class="-my-2 -mr-3 ml-auto grid size-10 shrink-0 place-items-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"
        >
          ✕
        </button>
      </div>
      <%= case @banner do %>
        <% {:ad, ad} -> %>
          <.markdown_prose text={ad.content} class="mt-2 min-w-0 text-sm text-slate-700 dark:text-slate-300" />
        <% :house -> %>
          <p class="mb-0 mt-2 text-sm text-slate-700 dark:text-slate-300">
            {gettext("This spot is free today. One day, one ad, every visitor.")}
            <.link
              href={~p"/ads"}
              class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {gettext("Book your ad")}
            </.link>
          </p>
      <% end %>
    </aside>
    """
  end

  defp fade_out do
    JS.hide(
      transition:
        {"transition-opacity duration-500 motion-reduce:transition-none", "opacity-100",
         "opacity-0"},
      time: 500
    )
  end
end
