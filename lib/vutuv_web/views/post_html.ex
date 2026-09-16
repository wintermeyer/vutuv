defmodule VutuvWeb.PostHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.PostComponents
  import VutuvWeb.UserHelpers

  embed_templates("../templates/post/*")

  def range_label("7d"), do: gettext("Last 7 days")
  def range_label("30d"), do: gettext("Last 30 days")
  def range_label("1y"), do: gettext("Last year")

  def bucket_label(at, "hour") do
    finish = NaiveDateTime.add(at, 3 * 3_600 - 1, :second)
    "#{Calendar.strftime(at, "%d %b %Y, %H:00")}–#{Calendar.strftime(finish, "%H:%M UTC")}"
  end

  def bucket_label(at, "day"), do: Calendar.strftime(at, "%d %b %Y")

  def chart_tick_label(at, "hour"), do: Calendar.strftime(at, "%H")
  def chart_tick_label(at, "day"), do: Calendar.strftime(at, "%d %b")

  def chart_buckets([], _unit), do: []

  def chart_buckets(buckets, "hour") do
    counts =
      Enum.reduce(buckets, %{}, fn bucket, grouped ->
        at = %{bucket.at | hour: div(bucket.at.hour, 3) * 3}

        Map.update(
          grouped,
          at,
          Map.put(bucket, :at, at),
          &merge_chart_bucket(&1, bucket)
        )
      end)

    first = %{hd(buckets).at | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    last_bucket = List.last(buckets)
    last = %{last_bucket.at | hour: 21, minute: 0, second: 0, microsecond: {0, 0}}

    Stream.iterate(first, &NaiveDateTime.add(&1, 3 * 3_600, :second))
    |> Enum.take_while(&(NaiveDateTime.compare(&1, last) != :gt))
    |> Enum.map(&Map.get(counts, &1, empty_chart_bucket(&1)))
  end

  def chart_buckets(buckets, _unit), do: buckets

  def chart_width(buckets, "hour"), do: max(760, 50 + length(buckets) * 14)
  def chart_width(_buckets, _unit), do: 760

  def chart_day_labels(buckets) do
    buckets
    |> Enum.with_index()
    |> Enum.chunk_by(fn {bucket, _index} -> NaiveDateTime.to_date(bucket.at) end)
    |> Enum.map(fn group ->
      {first, first_index} = hd(group)
      %{label: Calendar.strftime(first.at, "%d %b"), index: first_index, count: length(group)}
    end)
  end

  def chart_peak(buckets), do: Enum.max_by(buckets, & &1.total)

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

  defp merge_chart_bucket(left, right) do
    likes = left.likes + right.likes
    reposts = left.reposts + right.reposts
    replies = left.replies + right.replies
    %{left | likes: likes, reposts: reposts, replies: replies, total: likes + reposts + replies}
  end

  defp empty_chart_bucket(at),
    do: %{at: at, likes: 0, reposts: 0, replies: 0, total: 0}

  def network_node_position(0, _count), do: {550, 370}

  def network_node_position(index, count) do
    angle = network_node_angle(index, count)
    radius = 175 + (index - 1) * 125 / max(count - 2, 1)
    {550 + :math.cos(angle) * radius, 370 + :math.sin(angle) * radius}
  end

  def network_label_transform(index, count, node) do
    angle = network_node_angle(index, count)
    {x, y} = network_node_position(index, count)
    offset = network_label_radius(node) + 12
    label_x = x + :math.cos(angle) * offset
    label_y = y + :math.sin(angle) * offset
    degrees = angle * 180 / :math.pi()
    rotation = if degrees > 90 and degrees < 270, do: degrees - 180, else: degrees

    "translate(#{label_x} #{label_y}) rotate(#{rotation})"
  end

  def network_label_anchor(index, count) do
    if :math.cos(network_node_angle(index, count)) < 0, do: "end", else: "start"
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

  defp network_node_angle(index, count),
    do: -:math.pi() / 2 + (index - 1) * 2 * :math.pi() / max(count - 1, 1)

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
