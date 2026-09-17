defmodule VutuvWeb.AdComponents do
  @moduledoc """
  The daily text ad as a card: what a profile and the feed carry (see
  `VutuvWeb.AdServing` and `VutuvWeb.Live.AdSlot`) and what the booking
  preview shows the buyer.
  """

  use VutuvWeb, :html

  alias Phoenix.LiveView.JS
  alias Vutuv.Ads.Ad
  alias VutuvWeb.AdServing

  @doc """
  The live card in one of its two places on a page, or nothing while the page
  has no ad. `ad` is the page's `@ad_slot` (see `VutuvWeb.Live.AdSlot`). A page
  carries both places: `:rail` leads the desktop rail, `:inline` stands near
  the top of the one column a phone has, where the address moves up into the
  label's line to keep the card short. `viewer` is the page's
  `@current_user`, which picks where the card's label leads.
  """
  attr(:ad, :map, required: true)
  attr(:placement, :atom, required: true, values: [:rail, :inline])
  attr(:viewer, :any, required: true)

  def ad_slot(assigns) do
    ~H"""
    <.ad_card
      :if={@ad}
      id={"ad-slot-#{@placement}"}
      class={if @placement == :rail, do: "hidden md:block", else: "md:hidden"}
      banner={@ad.banner}
      key={AdServing.key(@ad)}
      audience={if @viewer, do: :member, else: :visitor}
      address={if @placement == :inline, do: :head, else: :foot}
    />
    """
  end

  @doc """
  An ad card on the page-canvas grey, the way it will stand on a page: the
  booking preview, a member's bookings and the admin review show it so. It is
  never the live card, so it has no ✕ and no countdown.
  """
  attr(:id, :string, required: true)
  attr(:banner, :any, required: true)
  attr(:class, :any, default: nil)

  def ad_preview(assigns) do
    ~H"""
    <div class={["rounded-xl bg-slate-100 px-2 py-4 dark:bg-slate-950", @class]}>
      <.ad_card id={@id} banner={@banner} />
    </div>
    """
  end

  @doc """
  The ad card: the unmistakable label, then the title as the link, the
  sentence under it and the address the link leads to, either of the booked
  ad (`{:ad, ad}`) or of the house ad (`:house`) that sells the slot.
  `address` puts that address under the sentence (`:foot`) or beside the
  label (`:head`).

  A `key` (`VutuvWeb.AdServing.key/1`) makes it the live card: the ✕
  (`"dismiss-ad"`) inside a ring that empties while the card is in view, the
  `AdSlot` hook that runs that countdown, and a fade when the card leaves. The
  booking preview and the seen-ads page pass no key and get none of it.

  `audience` says who looks at a live card, and with it where the label leads
  and what the ✕ does: a `:member`'s label opens their seen ads and the ✕ hides
  ads for the day, a `:visitor`'s label opens the `/system/ads` offer page and the ✕
  closes this card. Without it the label is plain text. `footer` goes under
  the ad.
  """
  attr(:id, :string, required: true)
  attr(:banner, :any, required: true)
  attr(:key, :string, default: nil)
  attr(:audience, :atom, default: nil, values: [nil, :member, :visitor])
  attr(:address, :atom, default: :foot, values: [:head, :foot])
  attr(:class, :any, default: nil)
  slot(:footer)

  def ad_card(assigns) do
    assigns = assign(assigns, :text, ad_text(assigns.banner))

    ~H"""
    <aside
      id={@id}
      aria-label={gettext("Ad")}
      phx-hook={@key && "AdSlot"}
      phx-remove={@key && fade_out()}
      data-ad-key={@key}
      class={[
        "rounded-2xl bg-white px-6 py-5 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800",
        @class
      ]}
    >
      <div class="flex items-center gap-3">
        <%!-- As a link the label keeps its look and grows an invisible
        touch target (`after:`) around itself. --%>
        <.link
          :if={@audience}
          href={label_href(@audience)}
          title={label_title(@audience)}
          class="relative shrink-0 rounded border border-slate-300 px-1 text-[10px] font-semibold uppercase tracking-wide text-slate-600 after:absolute after:-inset-3 hover:border-slate-500 hover:text-slate-900 dark:border-slate-600 dark:text-slate-400 dark:hover:border-slate-400 dark:hover:text-slate-100"
        >{gettext("Ad")}</.link>
        <span
          :if={!@audience}
          class="shrink-0 rounded border border-slate-300 px-1 text-[10px] font-semibold uppercase tracking-wide text-slate-600 dark:border-slate-600 dark:text-slate-400"
        >{gettext("Ad")}</span>
        <span :if={@address == :head} class="min-w-0 truncate text-xs text-slate-600 dark:text-slate-400">
          {@text.address}
        </span>
        <button
          :if={@key}
          type="button"
          phx-click="dismiss-ad"
          aria-label={dismiss_label(@audience)}
          title={dismiss_label(@audience)}
          class="relative -my-2 -mr-3 ml-auto grid size-10 shrink-0 place-items-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-200"
        >
          <%!-- The countdown: the arc empties while the card is in view. Its
          length is 1 (`pathLength`), so the dash offset the hook sets is the
          share of the time that has run; the server only draws it full and
          leaves it alone afterwards. --%>
          <svg
            id={"#{@id}-ring"}
            phx-update="ignore"
            class="pointer-events-none absolute left-1.5 top-1.5 size-7 -rotate-90"
            viewBox="0 0 28 28"
            fill="none"
            stroke-width="1.75"
            aria-hidden="true"
          >
            <circle cx="14" cy="14" r="12" class="stroke-slate-200 dark:stroke-slate-700" />
            <circle
              data-ad-ring-arc
              cx="14"
              cy="14"
              r="12"
              pathLength="1"
              stroke-dasharray="1"
              stroke-linecap="round"
              class="stroke-slate-500 dark:stroke-slate-400"
            />
          </svg>
          <span aria-hidden="true">✕</span>
        </button>
      </div>
      <.link
        href={@text.href}
        target={@text.target}
        rel={@text.rel}
        data-ad-link
        class="mt-2 block break-words text-base font-semibold leading-snug text-brand-600 hover:text-brand-700 hover:underline dark:text-brand-400 dark:hover:text-brand-300"
      >
        {@text.title}
      </.link>
      <p class="mb-0 mt-0.5 break-words text-sm text-slate-700 dark:text-slate-300">{@text.body}</p>
      <p :if={@address == :foot} class="mb-0 mt-1 truncate text-xs text-slate-600 dark:text-slate-400">
        {@text.address}
      </p>
      {render_slot(@footer)}
    </aside>
    """
  end

  # What the card says, for a booked ad and for the house ad. A booked link
  # leaves in a new tab and says it was paid for; the house ad's stays here.
  defp ad_text({:ad, %Ad{} = ad}) do
    %{
      title: ad.title,
      body: ad.body,
      href: ad.url,
      address: Ad.display_url(ad.url),
      target: "_blank",
      rel: "sponsored noopener"
    }
  end

  defp ad_text(:house) do
    %{
      title: gettext("Book your ad"),
      body: gettext("This spot is free today. One day, one ad, every visitor."),
      href: ~p"/system/ads",
      address: Ad.display_url(url(~p"/system/ads")),
      target: nil,
      rel: nil
    }
  end

  defp dismiss_label(:member), do: gettext("Hide ads for today")
  defp dismiss_label(:visitor), do: gettext("Close this ad")

  defp label_href(:member), do: ~p"/system/ads/seen"
  defp label_href(:visitor), do: ~p"/system/ads"

  defp label_title(:member), do: gettext("Ads you have seen")
  defp label_title(:visitor), do: gettext("How ads work on vutuv")

  defp fade_out do
    JS.hide(
      transition:
        {"transition-opacity duration-500 motion-reduce:transition-none", "opacity-100",
         "opacity-0"},
      time: 500
    )
  end
end
