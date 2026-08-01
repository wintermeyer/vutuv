defmodule VutuvWeb.RemoteContentSeoTest do
  @moduledoc """
  What a search engine may do with somebody else's post on our domain.

  Our own copy of a remote post lives on a members' page (`/system/fediverse/*`
  is login-gated and `noindex`, see `VutuvWeb.Plug.NoIndex`), but the card
  itself also appears on two pages a crawler reads: a public tag timeline, and
  a member's profile once they reshare one. Two rules follow from that, and
  neither of them is "hide the card":

    * the passage a search result quotes under a vutuv URL must be ours, so the
      foreign text carries `data-nosnippet`;
    * the links inside that text are the remote author's editorial choice, not
      our recommendation, so they are marked `ugc nofollow`.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Fediverse.Hashtags
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.PostsHelpers
  alias Vutuv.Tags.Tag
  alias VutuvWeb.Markdown

  defp tag_with_post(body) do
    name = unique_tag_name("Seo")
    PostsHelpers.create_post!(insert(:activated_user), %{body: body, tags: name})

    Repo.get_by!(Tag, name: name)
  end

  defp remote_post(tag, text) do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them-#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        name: "Them Themself",
        inbox_uri: "https://social.example/inbox"
      })

    now = DateTime.utc_now(:second)

    post =
      Repo.insert!(%RemotePost{
        remote_account_id: account.id,
        object_uri: "https://social.example/posts/#{System.unique_integer([:positive])}",
        origin_url: "https://social.example/@them/1",
        content_text: text,
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400)
      })

    Hashtags.sync(post, %{"tag" => [%{"type" => "Hashtag", "name" => "#" <> tag.name}]})
    post
  end

  describe "links inside a cached remote post" do
    test "an autolinked URL is marked ugc nofollow" do
      html = Markdown.render_remote("Mehr dazu: https://drnik.org/tausendfusser.html")

      assert html =~ ~s(rel="ugc nofollow noopener noreferrer")
      refute html =~ ~s(rel="noopener noreferrer")
    end

    test "so is a @user@host handle, which also leaves the site" do
      html = Markdown.render_remote("Siehe @hostsharing@geno.social")

      assert html =~ ~s(href="https://geno.social/@hostsharing")
      assert html =~ ~s(rel="ugc nofollow noopener noreferrer")
    end

    test "a #hashtag pointing at our own tag page keeps its ranking signal" do
      # Name and slug have to agree here (and stay inside the hashtag charset),
      # so this one is built by hand rather than from the factory sequence.
      n = System.unique_integer([:positive])
      tag = insert(:tag, name: "Crochet#{n}", slug: "crochet#{n}")
      insert(:user_tag, user: insert_activated_user(), tag: tag)

      html = Markdown.render_remote("Kleine Kritzelei ##{tag.name}")

      assert html =~ ~s(<a href="/tags/#{tag.slug}" class="hashtag">)
      refute html =~ ~s(href="/tags/#{tag.slug}" class="hashtag" rel=)
      refute html =~ "nofollow"
    end

    test "a member's own post is not marked — those links are ours to vouch for" do
      html =
        "Mehr dazu: https://drnik.org/tausendfusser.html"
        |> Markdown.render_post([])
        |> Phoenix.HTML.safe_to_string()

      assert html =~ ~s(rel="noopener noreferrer")
      refute html =~ "nofollow"
    end
  end

  describe "the public tag page a crawler reads" do
    test "shows the remote post and keeps its text out of the snippet", %{conn: conn} do
      tag = tag_with_post("Ein Beitrag von hier")
      remote_post(tag, "Ein Beitrag von woanders")

      body = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      # The card really is in the crawled HTML — this is not a page where the
      # foreign text only appears after a socket connects.
      assert body =~ "Ein Beitrag von woanders"
      assert body =~ "data-nosnippet"
    end

    test "our own post carries no such marker", %{conn: conn} do
      tag = tag_with_post("Ein Beitrag von hier")
      remote_post(tag, "Ein Beitrag von woanders")

      body = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      assert body =~ "Ein Beitrag von hier"
      # One card is foreign, one is ours, so exactly one marker.
      assert length(Regex.scan(~r/data-nosnippet/, body)) == 1
    end
  end
end
