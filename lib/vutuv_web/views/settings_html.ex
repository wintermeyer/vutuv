defmodule VutuvWeb.SettingsHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Accounts.User

  embed_templates("../templates/settings/*")

  @doc """
  The two choices for how often the unread-message email is sent, as
  `{label, value}` pairs for a `select` on `dm_email_each_message?` (a boolean).
  """
  def dm_frequency_options do
    [
      {gettext("Only the first message"), false},
      {gettext("Every message"), true}
    ]
  end

  @doc """
  The unread-message delay presets as `{label, minutes}` pairs, driven by the
  single source of truth in `Vutuv.Accounts.User.dm_email_delay_values/0` so the
  select can never offer a value the changeset rejects.
  """
  def dm_delay_options do
    Enum.map(User.dm_email_delay_values(), &{dm_delay_label(&1), &1})
  end

  # Explicit per-value labels (rather than interpolating the integer) so no bare
  # count reaches the UI and adding a preset without a label fails loudly here.
  defp dm_delay_label(0), do: gettext("As soon as possible")
  defp dm_delay_label(5), do: gettext("After 5 minutes")
  defp dm_delay_label(15), do: gettext("After 15 minutes")
  defp dm_delay_label(30), do: gettext("After 30 minutes")
  defp dm_delay_label(60), do: gettext("After 1 hour")
  defp dm_delay_label(120), do: gettext("After 2 hours")

  @doc """
  One row on the settings subpages' cards: a title, an optional sub-line, and a
  right-aligned text link to where the thing is actually managed. Keeps the
  lists tidy and DRY.
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
  The desktop frame the hub shares with its subpages: the persistent
  `<.settings_sidebar>` on the left (md+), the "Settings" title + "View profile"
  link on the right, and the page body in the slot. This closes the gap the hub
  used to have — it was a lonely centered column while every subpage carried
  this sidebar, so the layout jumped on every click into a subpage. Mobile is
  unchanged: the sidebar is hidden and the body reads as the single centered
  column it always did (`max-w-2xl`, dropped only from md up so the content
  fills the wide column beside the sidebar, exactly like a subpage).
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  slot(:inner_block, required: true)

  def hub_frame(assigns) do
    ~H"""
    <div class="py-6 md:grid md:grid-cols-[13rem_minmax(0,1fr)] md:gap-8">
      <.settings_sidebar
        user={@user}
        class="hidden self-start md:sticky md:top-20 md:block"
      />
      <div class="mx-auto w-full min-w-0 max-w-2xl md:mx-0 md:max-w-none">
        <div class="mb-6 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
          <h1 class="text-2xl font-bold text-slate-900 dark:text-white">{gettext("Settings")}</h1>
          <.link
            navigate={~p"/#{@user}"}
            class="text-sm font-medium text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
          >
            {gettext("View profile")} ›
          </.link>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
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
          href={~p"/settings/devices/#{@session.id}"}
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

  @doc """
  One row of the passkeys list (issue #795): the member-given name, when it was
  enrolled and last used, and a "Remove" action. Mirrors `device_row/1`.
  """
  attr(:passkey, :map, required: true)
  attr(:user, :map, required: true)

  def passkey_row(assigns) do
    ~H"""
    <li class="flex items-start justify-between gap-4 py-4">
      <div class="flex min-w-0 gap-3">
        <span class="mt-0.5 shrink-0 text-slate-400 dark:text-slate-500" aria-hidden="true">
          <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M15.75 5.25a3 3 0 0 1 3 3m3 0a6 6 0 0 1-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H9v1.5H7.5v1.5H6v-1.5l4.66-4.66c.404-.404.527-1 .43-1.563A6 6 0 1 1 21.75 8.25Z"
            />
          </svg>
        </span>
        <span class="min-w-0">
          <span class="block truncate font-medium text-slate-900 dark:text-white">
            {@passkey.nickname || gettext("Passkey")}
          </span>
          <span class="block text-sm text-slate-600 dark:text-slate-400">
            {gettext("Added")}: {Calendar.strftime(@passkey.inserted_at, "%Y-%m-%d")}<span :if={
              @passkey.last_used_at
            }>
              · {gettext("Last used")}: {last_active(@passkey.last_used_at)}</span>
          </span>
        </span>
      </div>
      <div class="shrink-0">
        <.link
          href={~p"/settings/passkeys/#{@passkey.id}"}
          method="delete"
          data-confirm={gettext("Remove this passkey?")}
          class="text-sm font-semibold text-red-600 hover:text-red-700 dark:text-red-400 dark:hover:text-red-300"
        >
          {gettext("Remove")}
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
