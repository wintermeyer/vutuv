defmodule VutuvWeb.LayoutHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/layout/*")

  @doc """
  Minimal, serializable session map handed to the embedded `ShellLive` so it can
  render the logged-in chrome (name, avatar initials, profile link) over both a
  dead request and a LiveView socket. Empty map when logged out.
  """
  def shell_session(assigns) do
    case assigns[:current_user] do
      %Vutuv.Accounts.User{} = user ->
        %{
          "user_id" => user.id,
          "user_name" => full_name(user),
          "user_param" => Phoenix.Param.to_param(user),
          "path" => current_path(assigns)
        }

      _ ->
        %{}
    end
  end

  # The current path lets the shell zero the matching unread badge at mount —
  # relying only on the page's read-broadcast races the shell's subscribe on
  # full page loads. Dead pages have @conn; LiveView layouts only have @socket,
  # so the badge-clearing pages are mapped from their view module.
  defp current_path(%{conn: conn}) when not is_nil(conn), do: conn.request_path
  defp current_path(%{socket: %{view: VutuvWeb.NotificationLive.Index}}), do: "/notifications"
  defp current_path(%{socket: %{view: VutuvWeb.MessageLive.Index}}), do: "/messages"

  defp current_path(_assigns) do
    nil
  end
end
