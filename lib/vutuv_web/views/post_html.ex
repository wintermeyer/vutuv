defmodule VutuvWeb.PostHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.PostComponents
  import VutuvWeb.UserHelpers

  embed_templates("../templates/post/*")

  def range_label("7d"), do: gettext("7 days")
  def range_label("30d"), do: gettext("30 days")
  def range_label("1y"), do: gettext("1 year")

  def bucket_label(at, "hour"), do: Calendar.strftime(at, "%d %b %Y, %H:00 UTC")
  def bucket_label(at, "day"), do: Calendar.strftime(at, "%d %b %Y")

  def network_node_position(0, _count), do: {400, 210}

  def network_node_position(index, count) do
    angle = -:math.pi() / 2 + (index - 1) * 2 * :math.pi() / max(count - 1, 1)
    radius = if rem(index, 2) == 0, do: 158, else: 184
    {400 + :math.cos(angle) * radius, 210 + :math.sin(angle) * radius}
  end

  def network_node_radius(%{status: :origin}), do: 31
  def network_node_radius(%{status: :addressed}), do: 8

  def network_node_radius(%{interactions: interactions}) do
    min(10 + :math.sqrt(interactions) * 3, 26)
  end

  @doc """
  The author-facing audience summary: one short label per denial. Only ever
  rendered for the post's owner — readers must not see the deny list.
  """
  def denial_labels(post) do
    Enum.map(post.denials, &denial_label/1)
  end

  defp denial_label(%{wildcard: wildcard}) when is_binary(wildcard), do: wildcard_label(wildcard)
  defp denial_label(%{denied_user: %{} = user}), do: full_name(user)
  defp denial_label(_), do: gettext("unknown")
end
