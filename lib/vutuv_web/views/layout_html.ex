defmodule VutuvWeb.LayoutHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/layout/*")

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
