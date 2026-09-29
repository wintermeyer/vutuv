defmodule VutuvWeb.TagSuggestControllerTest do
  @moduledoc """
  The JSON behind every tag field's suggestion list (`/system/tags/suggest`).

  It has to answer a visitor who is not signed in, because the first tag field
  anybody meets is the sign-up form's.
  """
  use VutuvWeb.ConnCase, async: true

  defp tag(name, members) do
    tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
    for _ <- 1..members//1, do: insert(:user_tag, user: insert(:activated_user), tag: tag)
    tag
  end

  setup do
    %{p: "zq#{System.unique_integer([:positive])}"}
  end

  test "answers a signed-out visitor with the typed row and the matches", %{conn: conn, p: p} do
    tag("#{p}elixir", 2)
    tag("#{p}erlang", 1)

    body = conn |> get(~p"/system/tags/suggest?#{[q: "#{p}e"]}") |> json_response(200)

    # What was typed is always its own row, resolved to the topic it names
    # (here none yet, so it passes through with nobody behind it).
    assert body["typed"] == %{"name" => "#{p}e", "count" => 0}

    assert [
             %{"name" => first, "count" => 2, "alias" => nil},
             %{"name" => second, "count" => 1}
           ] = body["results"]

    assert first == "#{p}elixir"
    assert second == "#{p}erlang"
  end

  test "the typed row resolves an existing topic, whatever the spelling", %{conn: conn, p: p} do
    tag("#{p} Open Source", 3)

    body = conn |> get(~p"/system/tags/suggest?#{[q: "#{p}-OPEN-source"]}") |> json_response(200)

    assert body["typed"] == %{"name" => "#{p} Open Source", "count" => 3}
    # And the typed topic is not offered a second time below itself.
    assert body["results"] == []
  end

  test "an empty query answers nothing", %{conn: conn} do
    assert %{"typed" => nil, "results" => []} =
             conn |> get(~p"/system/tags/suggest?q=") |> json_response(200)
  end

  test "counts for names already in a box", %{conn: conn, p: p} do
    tag("#{p}rust", 2)

    body =
      conn
      |> get(~p"/system/tags/suggest?#{[names: "#{p}RUST,#{p}nothing"]}")
      |> json_response(200)

    assert body["counts"] == [
             %{"name" => "#{p}rust", "typed" => "#{p}RUST", "count" => 2},
             %{"name" => "#{p}nothing", "typed" => "#{p}nothing", "count" => 0}
           ]
  end
end
