defmodule VutuvWeb.PostHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.PostComponents
  import VutuvWeb.UserHelpers

  embed_templates("../templates/post/*")

  @doc """
  The author-facing audience summary: one short label per denial. Only ever
  rendered for the post's owner — readers must not see the deny list.
  """
  def denial_labels(post) do
    Enum.map(post.denials, &denial_label/1)
  end

  defp denial_label(%{wildcard: "everyone"}), do: gettext("everyone else")
  defp denial_label(%{wildcard: "non_followers"}), do: gettext("people who don't follow you")
  defp denial_label(%{wildcard: "non_followees"}), do: gettext("people you don't follow")
  defp denial_label(%{wildcard: "logged_out"}), do: gettext("logged-out visitors")
  defp denial_label(%{group: %{name: name}}) when is_binary(name), do: name
  defp denial_label(%{denied_user: %{} = user}), do: full_name(user)
  defp denial_label(_), do: gettext("unknown")
end
