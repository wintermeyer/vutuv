defmodule VutuvWeb.AgentDocs.JobBoardReachDocTest do
  @moduledoc """
  The `/jobs` agent siblings when the board is empty.

  With no posting, the HTML board stops being a board and shows the other side
  of the market — the members who said they are available, and the fields they
  carry. An agent reading `/jobs.json` must get the same two facts, or the
  document answers "nobody is hiring" where the page answers "nobody is hiring
  yet, and here is who is here" (the drift rule in `CLAUDE.md`).

  The document is the **anonymous** view, so a `members`-only availability
  belongs in neither.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.JobsHelpers

  test "the empty board's document carries the available members and the fields" do
    tag = insert(:tag, name: "Reach Doc Elixir", slug: "reach_doc_elixir")

    seeker =
      insert(:activated_user,
        employment_status: "open",
        employment_status_visibility: "everyone",
        desired_workplace_types: ["remote"]
      )

    insert(:user_tag, user: seeker, tag: tag)

    doc = build_conn() |> get(~p"/jobs.json") |> json_response(200)

    assert doc["count"] == 0
    assert [person] = doc["open_to_offers"]
    assert person["employment_status"] == "open"
    assert person["desired_workplace_types"] == ["remote"]
    assert Enum.any?(doc["fields"], &(&1["name"] == "Reach Doc Elixir" and &1["members"] == 1))

    # And the Markdown sibling says it in words rather than dropping the block.
    md = build_conn() |> get(~p"/jobs.md") |> response(200)
    assert md =~ "Who you would reach"
    assert md =~ "Reach Doc Elixir"
  end

  test "a members-only availability stays out of the anonymous document" do
    insert(:activated_user,
      employment_status: "looking",
      employment_status_visibility: "members"
    )

    doc = build_conn() |> get(~p"/jobs.json") |> json_response(200)

    assert doc["open_to_offers"] == []
  end

  test "a board with a posting carries neither key" do
    publish_job!()

    doc = build_conn() |> get(~p"/jobs.json") |> json_response(200)

    assert doc["count"] == 1
    refute Map.has_key?(doc, "open_to_offers")
    refute Map.has_key?(doc, "fields")
  end
end
