defmodule VutuvWeb.LayoutHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

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
