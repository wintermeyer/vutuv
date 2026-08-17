defmodule VutuvWeb.MastodonApi.PaginationTest do
  @moduledoc """
  Walking a timeline backwards, which is what every Mastodon client does the
  moment you scroll. Before this the adapter only ever answered the newest page.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.UUIDv7

  describe "UUIDv7.timestamp/1" do
    test "is the inverse of generate_at/1, which is what the merged feed needs" do
      moment = ~N[2026-08-16 12:34:56]
      id = UUIDv7.generate_at(moment)

      assert UUIDv7.timestamp(id) == moment
    end

    test "answers nil for anything that is not a v7 uuid" do
      assert UUIDv7.timestamp("not-a-uuid") == nil
      assert UUIDv7.timestamp(nil) == nil
      assert UUIDv7.timestamp(Ecto.UUID.generate()) == nil
    end
  end

  describe "GET /api/v1/timelines/home" do
    setup do
      reader = insert(:activated_user)
      author = insert(:activated_user)
      {:ok, _} = Social.follow(reader, author.id)

      posts =
        Enum.map(1..5, fn n ->
          {:ok, post} = Posts.create_post(author, %{body: "Beitrag #{n}"})
          post
        end)

      {:ok, reader: reader, posts: posts}
    end

    test "limit caps the page and a Link header offers the next one", %{
      conn: conn,
      reader: reader
    } do
      token = mastodon_token(reader, ["read"])
      response = conn |> mastodon_conn(token) |> get("/api/v1/timelines/home?limit=2")

      assert [first, second] = json_response(response, 200)
      assert first["content"] =~ "Beitrag 5"
      assert second["content"] =~ "Beitrag 4"

      [link] = get_resp_header(response, "link")
      assert link =~ ~s(rel="next")
      assert link =~ "max_id=#{second["id"]}"
    end

    test "max_id walks back through the whole timeline without gaps or repeats", %{
      reader: reader
    } do
      token = mastodon_token(reader, ["read"])

      {collected, _} =
        Enum.reduce(1..3, {[], nil}, fn _page, {seen, cursor} ->
          query = if cursor, do: "?limit=2&max_id=#{cursor}", else: "?limit=2"
          body = build_conn() |> mastodon_conn(token) |> get("/api/v1/timelines/home" <> query)
          statuses = json_response(body, 200)
          {seen ++ statuses, List.last(statuses)["id"]}
        end)

      bodies = Enum.map(collected, & &1["content"])

      assert length(collected) == 5
      assert length(Enum.uniq(Enum.map(collected, & &1["id"]))) == 5

      assert Enum.map(5..1//-1, &"Beitrag #{&1}") ==
               Enum.map(bodies, fn body -> Regex.run(~r/Beitrag \d/, body) |> hd() end)
    end

    test "the last page offers no next link, so a client stops", %{conn: conn, reader: reader} do
      token = mastodon_token(reader, ["read"])
      response = conn |> mastodon_conn(token) |> get("/api/v1/timelines/home?limit=40")

      assert length(json_response(response, 200)) == 5
      refute get_resp_header(response, "link") |> Enum.join() =~ ~s(rel="next")
    end

    test "an unparsable max_id answers the newest page instead of nothing", %{
      conn: conn,
      reader: reader
    } do
      token = mastodon_token(reader, ["read"])

      statuses =
        conn
        |> mastodon_conn(token)
        |> get("/api/v1/timelines/home?limit=2&max_id=garbage")
        |> json_response(200)

      assert length(statuses) == 2
      assert hd(statuses)["content"] =~ "Beitrag 5"
    end
  end
end
