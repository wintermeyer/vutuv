defmodule VutuvWeb.ComposerPublishSwitchesTest do
  @moduledoc """
  What the composer asks before publishing (issue #2107), and — as much of this
  file's point as the rest — what it deliberately does **not** ask.

  It asks one thing: whether the files travelling with the post have their
  metadata removed. That is a question about *these* files, so it belongs beside
  them. Whether search engines and AI may read the post is a standing decision
  the member takes once on `/settings/privacy` and the server stamps onto the
  row as it publishes; asking it per post was one question too many, and a
  composer that asks nothing about it is the assertion below.

  The file half depends on `qpdf` being on the box, which is an installation
  fact, so it lives in `Vutuv.PostPublishSwitchesTest`. What is asserted here is
  what the author sees and what survives a reload.

  `async: false` — the attachment config is application env, which is global.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  defp post_it(live, params) do
    live |> form("#composer-form", %{"post" => params}) |> render_submit()
  end

  describe "the composer and the machines question" do
    test "publishes at once for a member who said no, carrying their answer", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      user
      |> Ecto.Changeset.change(posts_machines_allowed?: false)
      |> Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/feed")
      post_it(live, %{"body" => "Nur für Menschen"})

      # One press, one post. Nothing held the submission behind a warning and
      # nothing asked the question a second time: the answer was given on the
      # settings page and the server applied it. That the composer no longer
      # asks is what this asserts — a refute against the removed switch's own
      # marker would pass whatever the composer did.
      assert %Post{noindex_noai?: true} = Repo.get_by!(Post, user_id: user.id)
    end

    test "and for everybody else the post allows machines", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      post_it(live, %{"body" => "Ganz normal"})

      assert %Post{noindex_noai?: false, strip_metadata?: true} =
               Repo.get_by!(Post, user_id: user.id)
    end
  end

  describe "removing the metadata from the files" do
    test "the switch is not offered while there is no file to clean", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      refute has_element?(live, "[data-strip-metadata-switch]")
    end
  end

  describe "editing a published post" do
    test "does not offer the metadata switch again", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "Schon draußen"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      # Rewriting a file already handed out is not an edit. Calibrated: the
      # switch really does render on a new post carrying one
      # (`Vutuv.PostPublishSwitchesTest` drives the file half).
      refute has_element?(live, "[data-strip-metadata-switch]")
    end
  end
end
