defmodule VutuvWeb.NotificationTimelineTest do
  @moduledoc """
  `VutuvWeb.NotificationLive.Timeline`: the pure half of /notifications.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Activity
  alias VutuvWeb.NotificationLive.Timeline

  @noon ~N[2026-09-23 10:00:00]

  defp at(minutes), do: NaiveDateTime.add(@noon, minutes, :minute)

  defp item(kind, minutes, extra \\ %{}) do
    Map.merge(
      %{
        id: "#{kind}-#{minutes}-#{System.unique_integer([:positive])}",
        kind: kind,
        at: at(minutes)
      },
      extra
    )
  end

  defp rows(blocks), do: for({:row, row} <- blocks, do: row)

  test "every kind the registry produces lands in a row" do
    # The registry (`Vutuv.Activity.kind_specs/4`) is the one place a kind is
    # declared; a kind this page did not place would simply never show.
    for kind <- Activity.kinds() do
      assert [%{type: type}] = rows(Timeline.build([item(kind, 0, %{actor_id: "a"})], []))
      assert type in [:words, :reactions, :people, :other], "#{kind} became #{inspect(type)}"
    end
  end

  test "a visit is a line between what came before and after it" do
    blocks =
      Timeline.build(
        [item("follower", -60, %{actor_id: "a"}), item("like", 60, %{post_id: "p"})],
        [
          %{at: @noon, source: "page"}
        ]
      )

    assert [
             {:day, _},
             {:row, %{type: :reactions}},
             {:visits, [%{at: @noon}]},
             {:row, %{type: :people}}
           ] =
             blocks
  end

  test "adjacent visits with nothing between them are one line" do
    blocks =
      Timeline.build([item("follower", -60, %{actor_id: "a"})], [
        %{at: at(10), source: "bell"},
        %{at: at(20), source: "page"}
      ])

    assert [{:day, _}, {:visits, [%{source: "bell"}, %{source: "page"}]}, {:row, _}] = blocks
  end

  test "what came after new_since is fresh and announced once, unless already dealt with" do
    blocks =
      Timeline.build(
        [
          item("reply", 30),
          item("reply", 40),
          item("reply", 50, %{seen?: true}),
          item("reply", -30)
        ],
        [],
        new_since: @noon
      )

    assert [{:fresh, 2, @noon}] = for({:fresh, _, _} = block <- blocks, do: block)
    assert Enum.map(rows(blocks), & &1.fresh?) == [false, true, true, false]
  end

  test "likes and reposts of one post between two looks are one row, counted per person" do
    blocks =
      Timeline.build(
        [
          item("like", 1, %{post_id: "p", actor_id: "anna"}),
          item("fediverse_reaction", 2, %{post_id: "p", actor_url: "u", reaction_kind: "like"}),
          item("fediverse_reaction", 3, %{post_id: "p", actor_url: "u", reaction_kind: "announce"}),
          item("like", 4, %{post_id: "other", actor_id: "anna"})
        ],
        []
      )

    assert [%{post_id: "other"}, %{post_id: "p", likes: 2, shares: 1, actors: actors}] =
             Enum.sort_by(rows(blocks), &(&1.post_id != "other"))

    assert length(actors) == 2
  end

  test "a follower and the connection a moment later are one connected person" do
    blocks =
      Timeline.build(
        [
          item("follower", 1, %{actor_id: "a", actor_name: "Ada"}),
          item("connection", 2, %{actor_id: "a", actor_name: "Ada"}),
          item("follower", 3, %{actor_id: "b", actor_name: "Ben"})
        ],
        []
      )

    assert [
             %{
               type: :people,
               persons: [%{name: "Ben", connected?: false}, %{name: "Ada", connected?: true}]
             }
           ] =
             rows(blocks)
  end

  test "only words keeps the rows that carry somebody's words" do
    blocks =
      Timeline.build(
        [
          item("reply", 1),
          item("mention", 2),
          item("like", 3, %{post_id: "p"}),
          item("follower", 4)
        ],
        [],
        only_words?: true
      )

    assert rows(blocks) |> Enum.map(& &1.item.kind) |> Enum.sort() == ["mention", "reply"]
  end
end
