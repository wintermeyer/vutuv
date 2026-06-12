defmodule VutuvWeb.Plug.AgentLinksTest do
  @moduledoc """
  HTTP `Link` headers for HTML-free discovery: every browser-pipeline
  response advertises /llms.txt and the sitemap; pages with agent-format
  siblings repeat their `<link rel="alternate">` set in the header (built
  from the same assign, so the two cannot drift); agent documents point
  back at their canonical HTML URL.
  """

  use VutuvWeb.ConnCase, async: true

  setup do
    user = insert_activated_user(active_slug: "linked_member", first_name: "Lina")
    %{user: user}
  end

  defp link_header(conn), do: conn |> get_resp_header("link") |> Enum.join(", ")

  test "the homepage advertises llms.txt and the sitemap" do
    links = build_conn() |> get("/") |> link_header()

    assert links =~ ~s(</llms.txt>; rel="describedby"; type="text/markdown")
    assert links =~ ~s(</sitemap.xml>; rel="sitemap")
  end

  test "a LiveView page carries the global links too" do
    links = build_conn() |> get("/search") |> link_header()

    assert links =~ ~s(</llms.txt>; rel="describedby")
  end

  test "profile HTML repeats its alternate set in the Link header" do
    conn = get(build_conn(), "/linked_member")
    links = link_header(conn)

    html = html_response(conn, 200)

    for ext <- ~w(.md .txt .json .vcf) do
      assert links =~ ~s(</linked_member#{ext}>; rel="alternate"),
             "missing #{ext} alternate in Link header"

      assert html =~ ~s(href="/linked_member#{ext}")
    end

    assert links =~
             ~s(</linked_member/posts/feed.xml>; rel="alternate"; type="application/rss+xml")
  end

  test "an agent document points back at its canonical HTML URL" do
    conn = get(build_conn(), "/linked_member.md")
    links = link_header(conn)

    assert links =~ ~s(<http://localhost:4001/linked_member>; rel="canonical"; type="text/html")
    assert links =~ ~s(</llms.txt>; rel="describedby")
  end

  test "the global links appear exactly once per response" do
    links = build_conn() |> get("/linked_member.md") |> link_header()

    occurrences = links |> String.split("rel=\"describedby\"") |> length()
    assert occurrences == 2, "describedby should appear exactly once, got: #{links}"
  end
end
