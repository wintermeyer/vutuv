defmodule VutuvWeb.PostRobotsOptOutTest do
  @moduledoc """
  A member's `noindex?` / `noai?` opt-outs have to reach **everything** their
  posts are served as, not only the HTML `<meta>` tag.

  `PostDoc.robots_axes/2`'s own docstring calls itself "the one derivation …
  so the two cannot disagree", and it dropped `author.noindex?` from the noindex
  axis entirely — only a *restricted* post noindexed. Meanwhile the layout
  derived a **third** answer from the same author (`LayoutHTML.robots_directives/1`
  reads `conn.assigns[:user]`, which the post routes do assign), so the page
  emitted `<meta name="robots" content="noindex">` while the response header and
  every `.md` / `.json` sibling said nothing at all.

  The archive (`/:slug/posts`) was silent on both axes for the same reason and
  never called `put_robots_header/3`.

  Calibrated against the un-fixed code, where every header assertion below is an
  empty list.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Posts

  defp posting_member(attrs) do
    user = insert_activated_user(attrs)
    {:ok, post} = Posts.create_post(user, %{body: "Ein ganz gewöhnlicher Beitrag."})
    {user, post}
  end

  test "a permalink carries the author's search opt-out in its header" do
    {user, post} = posting_member(noindex?: true, noai?: false)

    conn = get(build_conn(), Posts.path(post))

    assert html_response(conn, 200) =~ "Ein ganz gewöhnlicher Beitrag."
    assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    assert user.noindex?
  end

  test "and its AI opt-out, and both together" do
    {_user, post} = posting_member(noindex?: false, noai?: true)

    assert build_conn() |> get(Posts.path(post)) |> get_resp_header("x-robots-tag") == [
             "noai, noimageai"
           ]

    {_user, both} = posting_member(noindex?: true, noai?: true)

    assert build_conn() |> get(Posts.path(both)) |> get_resp_header("x-robots-tag") ==
             ["noindex, noai, noimageai"]
  end

  test "a member who opted out of nothing gets no header" do
    {_user, post} = posting_member(noindex?: false, noai?: false)

    assert build_conn() |> get(Posts.path(post)) |> get_resp_header("x-robots-tag") == []
  end

  # The `.md` sibling is the machine-readable half of the same page, and it is
  # still served for a single opt-out (`agent_docs_blocked?` needs both), so the
  # choice has to travel with it.
  test "the agent-format sibling states the same opt-out" do
    {_user, post} = posting_member(noindex?: true, noai?: false)

    conn = get(build_conn(), Posts.path(post) <> ".md")

    assert response(conn, 200)
    assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
  end

  test "the post archive answers on both axes too" do
    {user, _post} = posting_member(noindex?: true, noai?: true)

    conn = get(build_conn(), ~p"/#{user.username}/posts")

    assert html_response(conn, 200)

    assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"],
           "the archive never stamped the header at all"
  end
end
