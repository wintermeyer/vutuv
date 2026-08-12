defmodule VutuvWeb.NotificationFilterCoverageTest do
  @moduledoc """
  The notifications page's filter tabs against the notification registry.

  `Vutuv.Activity.kind_specs/3` is the one place a notification kind is
  declared, but the page keeps its own map of which tab shows which kinds. A
  kind missing from that map is not merely absent from a tab: `filtered_out?/2`
  runs on the live-push branch too, so it is **dropped** for any reader who is
  not sitting on "All" — silently, and only for the readers who filter.

  That had already happened. `reference_check` shipped in v7.227.0 and was in
  none of the three tabs.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Activity
  alias VutuvWeb.NotificationLive.Index

  test "every registry kind is shown by exactly one tab" do
    tabs = Map.delete(Index.filters(), "all")
    covered = tabs |> Map.values() |> List.flatten()

    for kind <- Activity.kinds() do
      assert kind in covered,
             """
             The notification kind #{inspect(kind)} is in Vutuv.Activity's registry but in no \
             filter tab, so the page can never show it and a live-pushed one is dropped for \
             every reader not on "All". Add it to a tab in VutuvWeb.NotificationLive.Index.\
             """
    end

    # Twice would put one row under two tabs and double it in "all"'s siblings.
    duplicates = covered -- Enum.uniq(covered)
    assert duplicates == [], "kinds listed under more than one tab: #{inspect(duplicates)}"
  end

  test "no tab lists a kind the registry does not produce" do
    kinds = Activity.kinds()

    for {tab, listed} <- Map.delete(Index.filters(), "all"), kind <- listed do
      assert kind in kinds,
             "tab #{inspect(tab)} lists #{inspect(kind)}, which no longer exists in the registry"
    end
  end
end
