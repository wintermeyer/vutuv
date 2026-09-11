defmodule VutuvWeb.WithheldPostProfileHtmlTest do
  @moduledoc """
  `/:slug` is public, anonymous, in the sitemap and carries **no**
  `X-Robots-Tag`, so a crawler reads whatever is in it. Two queries put a
  withheld post's whole body there (issue #2107), both by reaching the page on
  a path the listing gates never touched:

    * the **who-to-follow rail** (`Vutuv.Posts.recent_posts_by_authors/3`),
      which selects `body:` into **bare maps** — nothing struct-shaped, so no
      per-entry redaction could ever have caught it; and
    * the **pinned post card** (`Vutuv.Posts.pinned_post/2`), fetched by id
      rather than through a timeline, so no listing scope applied.

  The second is the sharper one: the same page's `profile.json` redacted it
  correctly and the ActivityPub `featured` collection left it out correctly,
  so the HTML was the one surface of three that handed it over.

  Both are now gated by `scope_machines_for/2` — the same per-row predicate the
  archive uses — which is why the author still sees their own on their own
  profile. `test/vutuv/post_body_chokepoint_test.exs` is what stops a third
  query appearing.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Posts

  @withheld "Interne Preisliste, nur für Menschen."

  # The rail only teases a post that landed (`min_likes` 1 by default), so the
  # fixtures are liked — otherwise the query answers empty and the test would
  # pass without ever reaching the gate.
  defp withheld_author do
    author = insert(:activated_user, noindex?: false, noai?: false, emails: [build(:email)])
    fan = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: @withheld, noindex_noai: "true"})
    {:ok, open} = Posts.create_post(author, %{body: "Ganz offen"})
    :ok = Posts.like_post(fan, post)
    :ok = Posts.like_post(fan, open)
    %{author: author, post: post, open: open}
  end

  describe "the pinned post card" do
    test "is not handed to an anonymous visitor", %{conn: conn} do
      %{author: author, post: post} = withheld_author()
      {:ok, author} = Posts.pin_to_profile(author, post)

      html = conn |> get("/#{author.username}") |> html_response(200)

      refute html =~ "Preisliste"
    end

    test "but the author still sees it on their own profile", %{conn: conn} do
      %{author: author, post: post} = withheld_author()
      {:ok, author} = Posts.pin_to_profile(author, post)

      html =
        conn
        |> login_via_pin(hd(author.emails).value)
        |> get("/#{author.username}")
        |> html_response(200)

      # The switch is about machines. Hiding a member's own pinned post from
      # their own profile would be a different feature, and the archive already
      # makes exactly this exception.
      assert html =~ "Preisliste"
    end
  end

  describe "the who-to-follow rail's post teasers" do
    test "quote an open post and never a withheld one" do
      %{author: author, post: post, open: open} = withheld_author()

      teasers = Posts.recent_posts_by_authors([author], nil, per_author: 5)
      quoted = Map.get(teasers, author.id, [])

      assert open.id in Enum.map(quoted, & &1.id)
      refute post.id in Enum.map(quoted, & &1.id)
      refute Enum.any?(quoted, &(&1.body =~ "Preisliste"))
    end

    test "keep the author's own when the author is the one reading" do
      %{author: author, post: post} = withheld_author()

      teasers = Posts.recent_posts_by_authors([author], author, per_author: 5)
      quoted = Map.get(teasers, author.id, [])

      assert post.id in Enum.map(quoted, & &1.id)
    end
  end
end
