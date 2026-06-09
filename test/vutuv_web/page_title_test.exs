defmodule VutuvWeb.PageTitleTest do
  @moduledoc """
  The <title> contract of the root layout: an explicit `page_title` assign
  wins (controllers and LiveViews set it), a page about a user falls back to
  the user's name, and everything else is the bare site name.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Posts

  defp title(conn) do
    [_, title] = Regex.run(~r|<title[^>]*>([^<]*)</title>|, conn.resp_body)
    title
  end

  test "the landing page gets the bare site name", %{conn: conn} do
    assert conn |> get("/") |> title() == "vutuv"
  end

  test "a user page without an explicit title names the user", %{conn: conn} do
    user = insert_activated_user(first_name: "Tina", last_name: "Titel")

    assert conn |> get("/#{user.active_slug}") |> title() == "Tina Titel - vutuv"
  end

  test "an explicit page_title wins over the user fallback", %{conn: conn} do
    user = insert_activated_user(first_name: "Tina", last_name: "Titel")
    {:ok, post} = Posts.create_post(user, %{body: "titled"})

    assert conn |> get(Posts.path(post)) |> title() ==
             "Tina Titel · #{Date.to_iso8601(post.published_on)} - vutuv"
  end

  test "a LiveView's page_title reaches the dead render too", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert conn |> get("/feed") |> title() == "Feed - vutuv"
  end
end
