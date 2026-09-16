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

  def chart_tick_label(at, "hour"), do: Calendar.strftime(at, "%d %b %H:00")
  def chart_tick_label(at, "day"), do: Calendar.strftime(at, "%d %b")

  def chart_tick_indices(count) when count <= 1, do: [0]

  def chart_tick_indices(count) do
    last = count - 1
    step = ceil(last / 6)
    ticks = Enum.take_every(0..last, step)

    case List.last(ticks) do
      ^last -> ticks
      previous when last - previous < max(div(step, 2), 1) -> List.replace_at(ticks, -1, last)
      _previous -> ticks ++ [last]
    end
  end

  def chart_tick_anchor(0, _count), do: "start"
  def chart_tick_anchor(index, count) when index == count - 1, do: "end"
  def chart_tick_anchor(_index, _count), do: "middle"

  def network_node_position(0, _count), do: {500, 300}

  def network_node_position(index, count) do
    angle = -:math.pi() / 2 + (index - 1) * 2 * :math.pi() / max(count - 1, 1)
    radius = 145 + (index - 1) * 125 / max(count - 2, 1)
    {500 + :math.cos(angle) * radius, 300 + :math.sin(angle) * radius}
  end

  def network_node_radius(%{status: :origin}), do: 31
  def network_node_radius(%{status: :addressed}), do: 8

  def network_node_radius(%{interactions: interactions}) do
    min(10 + :math.sqrt(interactions) * 3, 26)
  end

  def network_community_radius(%{active_month: active_month} = node)
      when is_integer(active_month) and active_month > 0 do
    network_node_radius(node) + min(7 + :math.log10(active_month) * 2, 18)
  end

  def network_community_radius(_node), do: nil

  def network_node_title(%{active_month: active_month, node_info_checked_at: checked_at} = node)
      when is_integer(active_month) and active_month > 0 and not is_nil(checked_at) do
    gettext(
      "%{host}: %{interactions} interactions · %{active} monthly active accounts · NodeInfo %{checked_at}",
      host: node.host,
      interactions: node.interactions,
      active: compact_count(active_month),
      checked_at: Calendar.strftime(checked_at, "%d %b %Y, %H:%M UTC")
    )
  end

  def network_node_title(node) do
    gettext("%{host}: %{interactions} interactions",
      host: node.host,
      interactions: node.interactions
    )
  end

  def network_elapsed_label(%{sequence: 1}), do: gettext("First visible reaction")

  def network_elapsed_label(%{elapsed_seconds: seconds})
      when is_integer(seconds) and seconds < 60,
      do: gettext("+%{count}s", count: seconds)

  def network_elapsed_label(%{elapsed_seconds: seconds})
      when is_integer(seconds) and seconds < 3_600,
      do: gettext("+%{count}m", count: div(seconds, 60))

  def network_elapsed_label(%{elapsed_seconds: seconds}) when is_integer(seconds),
    do: gettext("+%{count}h", count: div(seconds, 3_600))

  def network_elapsed_label(_node), do: nil

  def network_label_radius(node),
    do: max(network_node_radius(node), network_community_radius(node) || 0)

  def network_edge_width(%{repost_potential: count}) when is_integer(count) and count > 0 do
    min(2 + :math.log10(count + 1), 7)
  end

  def network_edge_width(%{status: :active}), do: 2
  def network_edge_width(_node), do: 1

  def repost_reach_bar_width(%{followers: followers}, max_followers)
      when is_integer(followers) and followers >= 0 and max_followers > 0 do
    max(3, :math.log10(followers + 1) / :math.log10(max_followers + 1) * 100)
  end

  def repost_reach_bar_width(_reposter, _max_followers), do: 0

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
