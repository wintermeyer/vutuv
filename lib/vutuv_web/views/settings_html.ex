defmodule VutuvWeb.SettingsHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/settings/*")

  @doc """
  One row on the account hub: a title, an optional sub-line, and a right-aligned
  text link to where the thing is actually managed. Keeps the hub's lists tidy
  and DRY.
  """
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:href, :string, required: true)
  attr(:label, :string, required: true)

  def account_row(assigns) do
    ~H"""
    <li class="flex items-center justify-between gap-4 py-3">
      <span class="min-w-0">
        <span class="block font-medium text-slate-900 dark:text-white">{@title}</span>
        <span :if={@subtitle} class="block truncate text-sm text-slate-600 dark:text-slate-400">
          {@subtitle}
        </span>
      </span>
      <.link
        navigate={@href}
        class="shrink-0 text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {@label}
      </.link>
    </li>
    """
  end

  @doc """
  One row of the signed-in-devices list (issue #794): the device/browser, its
  approximate location, when it was last active, and either a "this device"
  marker (the current session, no logout — you log it out via the normal logout)
  or a "Log out" action that revokes just that session.
  """
  attr(:session, :map, required: true)
  attr(:current?, :boolean, default: false)
  attr(:user, :map, required: true)

  def device_row(assigns) do
    ~H"""
    <li class="flex items-start justify-between gap-4 py-4">
      <div class="flex min-w-0 gap-3">
        <.device_glyph mobile?={Vutuv.Sessions.mobile?(@session.user_agent)} />
        <span class="min-w-0">
          <span class="block font-medium text-slate-900 dark:text-white">
            {Vutuv.Sessions.device_summary(@session.user_agent)}<span
              :if={@session.approx_location}
              class="text-slate-600 dark:text-slate-400"
            >
              · {@session.approx_location}</span>
          </span>
          <span class="block text-sm text-slate-600 dark:text-slate-400">
            {gettext("Last active")}: {last_active(@session.last_seen_at)}<span :if={@current?}>
              · <span class="font-medium text-brand-700 dark:text-brand-300">{gettext("This device")}</span></span>
          </span>
        </span>
      </div>
      <div class="shrink-0">
        <span
          :if={@current?}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-emerald-700 dark:text-emerald-400"
        >
          <span class="h-2 w-2 rounded-full bg-emerald-500"></span>
          {gettext("Active")}
        </span>
        <.link
          :if={!@current?}
          href={~p"/#{@user}/settings/devices/#{@session.id}"}
          method="delete"
          data-confirm={gettext("Log this device out of your account?")}
          class="text-sm font-semibold text-red-600 hover:text-red-700 dark:text-red-400 dark:hover:text-red-300"
        >
          {gettext("Log out")}
        </.link>
      </div>
    </li>
    """
  end

  attr(:mobile?, :boolean, default: false)

  # A small monitor / phone glyph so the list scans at a glance. Decorative, so
  # aria-hidden — the device summary text carries the meaning.
  defp device_glyph(assigns) do
    ~H"""
    <span class="mt-0.5 shrink-0 text-slate-400 dark:text-slate-500" aria-hidden="true">
      <svg :if={@mobile?} class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
        <rect x="7" y="3" width="10" height="18" rx="2" />
        <path d="M11 18h2" stroke-linecap="round" />
      </svg>
      <svg :if={!@mobile?} class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
        <rect x="3" y="4" width="18" height="12" rx="2" />
        <path d="M8 20h8M12 16v4" stroke-linecap="round" />
      </svg>
    </span>
    """
  end

  # A short, localized "last active" reading: just now / N minutes / N hours / N
  # days ago, falling back to an absolute date for anything older than a week.
  @doc false
  def last_active(nil), do: gettext("unknown")

  def last_active(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> gettext("just now")
      seconds < 3600 -> ngettext("%{count} minute ago", "%{count} minutes ago", div(seconds, 60))
      seconds < 86_400 -> ngettext("%{count} hour ago", "%{count} hours ago", div(seconds, 3600))
      seconds < 604_800 -> ngettext("%{count} day ago", "%{count} days ago", div(seconds, 86_400))
      true -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end
end
