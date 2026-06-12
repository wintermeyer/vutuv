defmodule VutuvWeb.LayoutHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers
  alias VutuvWeb.OpenGraph

  embed_templates("../templates/layout/*")

  @doc """
  One flash toast (the `#toast-tray` entry in `app.html.heex`). The info and
  error toasts are the same shell differing only in the outer ring colour, the
  ARIA role, the auto-dismiss flag, the icon-badge tint and the icon glyph, so
  they share this component. The full `class` strings are passed verbatim by
  the call site (the differing colour tokens are interleaved with shared ones,
  so splitting them out would reorder tokens); `kind` is the flash key that
  drives `phx-value-key`, `autodismiss` toggles `data-toast-autodismiss`, and
  the `:icon` slot carries the badge glyph.
  """
  attr(:kind, :string, required: true)
  attr(:msg, :string, required: true)
  attr(:role, :string, required: true)
  attr(:class, :string, required: true)
  attr(:badge_class, :string, required: true)
  attr(:autodismiss, :boolean, default: false)
  slot(:icon, required: true)

  def toast(assigns) do
    ~H"""
    <div class={@class} role={@role} data-toast-autodismiss={@autodismiss}>
      <span class={@badge_class}>
        {render_slot(@icon)}
      </span>
      <p class="text-sm text-slate-700 dark:text-slate-200">{@msg}</p>
      <button
        type="button"
        class="ml-auto shrink-0 text-slate-400 hover:text-slate-600"
        data-toast-close
        phx-click="lv:clear-flash"
        phx-value-key={@kind}
        aria-label={gettext("Close")}
      >
        ✕
      </button>
    </div>
    """
  end

  @doc """
  The discreet text-ad strip between the top navigation and the content
  (Google text-ad style; see `Vutuv.Ads` and `VutuvWeb.Plug.AdBanner`).
  Renders the booked ad's Markdown (`{:ad, ad}`) or the house ad (`:house`)
  that sells the slot, always with the unmistakable "Ad" label. The
  `id="vutuv-ad"` marker is the plug's seen-detection contract and
  `data-ad-banner` triggers the two-minute auto-hide in app.js.
  """
  attr(:banner, :any, required: true)

  def ad_banner(assigns) do
    ~H"""
    <div id="vutuv-ad" data-ad-banner class="mx-auto max-w-6xl px-4 pt-4">
      <.ad_banner_box banner={@banner} dismissible />
    </div>
    """
  end

  @doc """
  The banner box itself (label + content), without the live-banner wrapper:
  no `id="vutuv-ad"` (the plug's seen-detection marker) and no
  `data-ad-banner` (the two-minute auto-hide hook). The booking flow's
  preview page renders this directly, so the buyer sees exactly the box that
  will run - without burning their hourly slot or having the preview fade
  away under them.

  `dismissible` adds the ✕ that hides ads for the rest of the day (app.js
  writes the day-stamped cookie `VutuvWeb.Plug.AdBanner` honors). Only the
  live banner passes it - a ✕ on the preview page would set that cookie too.
  """
  attr(:banner, :any, required: true)
  attr(:dismissible, :boolean, default: false)

  def ad_banner_box(assigns) do
    ~H"""
    <div class="flex items-start gap-3 rounded-xl bg-white px-4 py-3 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800">
      <span class="mt-0.5 shrink-0 rounded border border-slate-300 px-1 text-[10px] font-semibold uppercase tracking-wide text-slate-500 dark:border-slate-600 dark:text-slate-400">{gettext("Ad")}</span>
      <%= case @banner do %>
        <% {:ad, ad} -> %>
          <div class="markdown min-w-0 text-sm text-slate-700 dark:text-slate-300">
            {VutuvWeb.Markdown.render(ad.content)}
          </div>
        <% :house -> %>
          <p class="mb-0 min-w-0 text-sm text-slate-700 dark:text-slate-300">
            {gettext("This spot is free today. One day, one ad, every visitor.")}
            <.link href={~p"/ads"} class="font-semibold text-brand-600 hover:text-brand-700">
              {gettext("Book your ad")}
            </.link>
          </p>
      <% end %>
      <button
        :if={@dismissible}
        type="button"
        data-ad-close
        data-ad-day={Vutuv.Ads.today()}
        aria-label={gettext("Hide ads for today")}
        title={gettext("Hide ads for today")}
        class="ml-auto shrink-0 text-slate-400 hover:text-slate-600 dark:hover:text-slate-300"
      >
        ✕
      </button>
    </div>
    """
  end

  @doc """
  The `<title>` content, sans the site-name suffix: an explicit `:page_title`
  assign wins (the post pages and the LiveViews set one), a page about a user
  (`:user` in the conn assigns) falls back to the user's name, and everything
  else gets `nil` so `live_title`'s default (the bare site name) applies.
  """
  def page_title(%{page_title: title}) when is_binary(title), do: title

  def page_title(%{conn: conn}) when not is_nil(conn) do
    case conn.assigns[:user] do
      %Vutuv.Accounts.User{} = user -> full_name(user)
      _ -> nil
    end
  end

  def page_title(_assigns), do: nil

  @doc """
  The robots meta directives for a page about a member (`:user` in the conn
  assigns): the member's search-engine and AI opt-outs rendered by
  `VutuvWeb.ContentPolicy.robots_directives/2`. `nil` (no meta tag) when
  the page is about nobody or the member opted out of nothing.
  """
  def robots_directives(%{conn: conn}) when not is_nil(conn) do
    case conn.assigns[:user] do
      %Vutuv.Accounts.User{} = user ->
        VutuvWeb.ContentPolicy.robots_directives(user.noindex?, user.noai?)

      _ ->
        nil
    end
  end

  def robots_directives(_assigns), do: nil

  @doc """
  Minimal, serializable session map handed to the embedded `ShellLive` so it can
  render the logged-in chrome (name, avatar, profile link) over both a dead
  request and a LiveView socket. `"user_avatar"` is `nil` when the user has no
  picture - the shell then falls back to initials. Empty map when logged out.
  """
  def shell_session(assigns) do
    case assigns[:current_user] do
      %Vutuv.Accounts.User{} = user ->
        %{
          "user_id" => user.id,
          "user_name" => full_name(user),
          "user_param" => Phoenix.Param.to_param(user),
          "user_avatar" => Vutuv.Avatar.user_url(user, :thumb),
          "path" => current_path(assigns)
        }

      _ ->
        %{}
    end
  end

  # The current path lets the shell zero the matching unread badge at mount —
  # relying only on the page's read-broadcast races the shell's subscribe on
  # full page loads. Dead pages have @conn; live pages get `:shell_path`
  # assigned from the URI by the `Live.InitAssigns` handle_params hook.
  defp current_path(%{conn: conn}) when not is_nil(conn), do: conn.request_path
  defp current_path(%{shell_path: path}), do: path
  defp current_path(_assigns), do: nil
end
