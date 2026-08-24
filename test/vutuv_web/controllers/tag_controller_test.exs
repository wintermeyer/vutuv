defmodule VutuvWeb.TagControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias VutuvWeb.Fediverse.Docs

  defp meta_description(html) do
    [_, content] = Regex.run(~r/<meta name="description" content="([^"]*)"/, html)
    content
  end

  defp og_tag(html, property) do
    case Regex.run(~r/<meta property="#{property}" content="([^"]*)"/, html) do
      [_, content] -> content
      _ -> nil
    end
  end

  # The CollectionPage block, or nil when the page emits none.
  defp collection_page(html) do
    ~r{<script type="application/ld\+json">\s*(.*?)\s*</script>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [json] -> Jason.decode!(json) end)
    |> Enum.find(&(&1["@type"] == "CollectionPage"))
  end

  # The public tag pages resolve the `:slug` param to a `Tags.Tag` before every
  # action. An unknown slug must render a clean 404 and *halt* (a missing tag
  # must not fall through into `show/2` with a nil assign). The `:index` action
  # carries no `:slug` param, so the resolver must pass through cleanly there and
  # still render the listing. These guard the swap to the shared resolver plug.

  describe "index (no slug param)" do
    test "renders the tag listing", %{conn: conn} do
      insert(:tag)
      conn = get(conn, ~p"/tags")
      assert conn.status == 200
    end
  end

  describe "show" do
    test "renders an existing tag", %{conn: conn} do
      tag = insert(:tag)
      conn = get(conn, ~p"/tags/#{tag}")
      assert conn.status == 200
    end

    test "returns a clean 404 on an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/tags/does-not-exist")
      assert conn.status == 404
      assert conn.halted
    end
  end

  # A tag page below the indexability bar (fewer than
  # Tags.min_indexable_members/0 visible members and no public post) is a thin
  # near-duplicate in a search index. It stays served and linkable, but carries
  # noindex so crawlers drop it deliberately instead of piling up in Search
  # Console as "crawled - currently not indexed"; the sitemap advertises only
  # tags above the bar.
  describe "search-engine indexability" do
    test "a thin tag page carries the noindex header", %{conn: conn} do
      tag = insert(:tag)
      insert(:user_tag, user: insert(:activated_user), tag: tag)

      conn = get(conn, ~p"/tags/#{tag}")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    test "a tag page above the bar is indexable", %{conn: conn} do
      tag = insert(:tag)

      for _ <- 1..Vutuv.Tags.min_indexable_members() do
        insert(:user_tag, user: insert(:activated_user), tag: tag)
      end

      conn = get(conn, ~p"/tags/#{tag}")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == []
    end

    test "the noindex rides the agent formats too", %{conn: conn} do
      tag = insert(:tag)

      conn = get(conn, ~p"/tags/#{tag}" <> ".md")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end
  end

  # Issue #946: a tag used only in posts (no endorsed members) used to open an
  # empty page. The tag page now lists everything carrying the tag, through the
  # embedded VutuvWeb.TagLive.Timeline - see tag_timeline_live_test.exs for the
  # controls. What matters here is that the dead render (what a crawler and a
  # visitor with no JavaScript get) already carries the posts.
  describe "posts with this tag (issue #946)" do
    test "a tag used only in posts still shows those posts", %{conn: conn} do
      author = insert(:activated_user)

      tag_name = unique_tag_name("Elixir")

      post =
        Vutuv.PostsHelpers.create_post!(author, %{body: "Elixir meetup notes", tags: tag_name})

      html = conn |> get(~p"/tags/#{Vutuv.SlugHelpers.tagify(tag_name)}") |> html_response(200)

      assert html =~ "tag-timeline"
      assert html =~ "Elixir meetup notes"
      assert html =~ "/#{author.username}/posts/#{post.id}"
      # The posts render as flat rows in one card (the feed/archive treatment),
      # not separate full-width cards - keeps the desktop layout tidy.
      assert html =~ "data-filter-list"
    end

    test "the front matter rides above the timeline whatever ?page says", %{conn: conn} do
      # The timeline pages over the socket now, so the description and the
      # member list no longer disappear on a `?page=2` that no longer drives
      # them.
      insert(:tag, name: "Busy", slug: "busy", description: "A very busy tag indeed.")

      html = conn |> get(~p"/tags/busy?page=2") |> html_response(200)

      assert html =~ "A very busy tag indeed."
    end

    test "an empty tag says so instead of showing a bare list", %{conn: conn} do
      insert(:tag, name: "Empty", slug: "empty")

      html = conn |> get(~p"/tags/empty") |> html_response(200)

      assert html =~ ~s(id="tag-timeline-empty")
      refute html =~ "data-filter-list"
    end
  end

  # The top of a tag page is for the posts. Two blocks used to sit above them on
  # every single tag page whatever they had to say: a card whose only content
  # was "this tag has no description yet" (an admin-only field, so the reader
  # cannot fix it), and the full Fediverse follow card.
  describe "the front-matter card" do
    test "a tag with nothing to say about itself renders no card at all", %{conn: conn} do
      tag = insert(:tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      refute html =~ "data-tag-front-matter"
      refute html =~ "description yet"
    end

    test "a described tag still gets the card", %{conn: conn} do
      insert(:tag, name: "Busy", slug: "busy", description: "A very busy tag indeed.")

      html = conn |> get(~p"/tags/busy") |> html_response(200)

      assert html =~ "data-tag-front-matter"
      assert html =~ "A very busy tag indeed."
    end

    test "a blank description counts as none", %{conn: conn} do
      insert(:tag, name: "Blank", slug: "blank", description: "   ")

      html = conn |> get(~p"/tags/blank") |> html_response(200)

      refute html =~ "data-tag-front-matter"
    end

    test "an endorsed member alone is enough to earn the card", %{conn: conn} do
      tag = insert(:tag)
      insert(:user_tag, user: insert(:activated_user), tag: tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      assert html =~ "data-tag-front-matter"
    end
  end

  describe "the tag's Fediverse address" do
    test "rides the header, with the follow form folded away below it", %{conn: conn} do
      tag = insert(:tag)
      handle = "@" <> Docs.acct(tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      # The address is the thing a visitor from another server came for, so it
      # stays in plain sight — once, on the header's meta line.
      assert html =~ handle
      assert html =~ ~s(id="tag-fediverse-handle")
      assert length(String.split(html, ~s(id="tag-fediverse-handle"))) == 2

      # The sentence and the remote-follow form are still on the page, but
      # behind a closed disclosure rather than an open card.
      assert html =~ ~s(<details id="tag-fediverse")
      assert html =~ ~s(id="remote-follow-form")
      refute html =~ ~s(<details id="tag-fediverse" open)
    end

    test "the German page names the disclosure in German", %{conn: conn} do
      tag = insert(:tag)

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/tags/#{tag}")
        |> html_response(200)

      assert html =~ "Aus dem Fediverse folgen"
    end
  end

  # What a search result and a shared link say about a tag page. The title used
  # to be the bare site name on every one of them, and the description promised
  # a list of members that most tag pages do not have.
  describe "search-engine and link-preview metadata" do
    test "the description says what the page holds", %{conn: conn} do
      tag = insert(:tag, name: "Elchtest", slug: "elchtest")

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      assert meta_description(html) == "Posts and members on vutuv about Elchtest."
    end

    test "a description written in the admin form wins", %{conn: conn} do
      insert(:tag, name: "Beam", slug: "beam", description: "The Erlang virtual machine.")

      html = conn |> get(~p"/tags/beam") |> html_response(200)

      assert meta_description(html) == "The Erlang virtual machine."
    end

    test "a long description is cut on a word boundary", %{conn: conn} do
      insert(:tag, name: "Lang", slug: "lang", description: String.duplicate("Wort ", 60))

      description = conn |> get(~p"/tags/lang") |> html_response(200) |> meta_description()

      assert String.length(description) <= 160
      assert String.ends_with?(description, "...")
    end

    test "og:title and og:description carry the same strings as the head", %{conn: conn} do
      tag = insert(:tag, name: "Elchtest", slug: "elchtest")

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      # og:title is the page title without the " - vutuv" suffix the browser tab
      # carries — the site name is already og:site_name.
      assert og_tag(html, "og:title") == "#Elchtest"
      assert og_tag(html, "og:description") == meta_description(html)
    end

    test "an indexable tag page describes its collection", %{conn: conn} do
      tag = insert(:tag)

      for _ <- 1..Tags.min_indexable_members() do
        insert(:user_tag, user: insert(:activated_user), tag: tag)
      end

      block = conn |> get(~p"/tags/#{tag}") |> html_response(200) |> collection_page()

      assert block["name"] == Tag.display_name(tag)
      assert block["url"] =~ "/tags/#{tag.slug}"
      assert block["description"] =~ Tag.display_name(tag)
      # The topic itself, named but not typed: nothing in a tag row says whether
      # it is a place, a language or a person.
      assert block["about"] == %{"@type" => "Thing", "name" => Tag.display_name(tag)}
    end

    test "a thin tag page carries no collection markup", %{conn: conn} do
      # Markup mirrors the page: this one already answers noindex, so telling a
      # crawler about a collection here would contradict it.
      tag = insert(:tag)
      insert(:user_tag, user: insert(:activated_user), tag: tag)

      conn = get(conn, ~p"/tags/#{tag}")

      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert conn |> html_response(200) |> collection_page() == nil
    end

    test "the German page describes itself in German", %{conn: conn} do
      tag = insert(:tag, name: "Elchtest", slug: "elchtest")

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/tags/#{tag}")
        |> html_response(200)

      assert meta_description(html) == "Beiträge und Mitglieder auf vutuv zum Thema Elchtest."
    end
  end

  # Issue #1338: one page per topic. An absorbed tag keeps its own row and slug
  # (that row IS the history), so its URL never dies — it leads to the topic.
  describe "a merged tag's slug" do
    setup do
      canonical = insert(:tag, name: "Ruby on Rails", slug: "ruby_on_rails")

      absorbed =
        insert(:tag,
          name: "rubyonrails",
          slug: "rubyonrails",
          merged_into_id: canonical.id,
          alias_kind: "former"
        )

      %{canonical: canonical, absorbed: absorbed}
    end

    test "redirects permanently to the canonical page", ctx do
      conn = get(ctx.conn, ~p"/tags/rubyonrails")

      # 301, never 302: permanent is what passes the ranking signal on to the
      # page that survived.
      assert conn.status == 301
      assert redirected_to(conn, 301) == ~p"/tags/ruby_on_rails"
    end

    test "carries the query string across", ctx do
      conn = get(ctx.conn, ~p"/tags/rubyonrails?source=fediverse&page=2")

      assert redirected_to(conn, 301) == ~p"/tags/ruby_on_rails?source=fediverse&page=2"
    end

    test "an agent format lands on the canonical page in the same format", ctx do
      # The `.md` sibling must not fall back to HTML, and must not 404: the
      # endpoint plug re-appends the extension to an in-app redirect, so the
      # controller only has to name the canonical path.
      conn = get(ctx.conn, "/tags/rubyonrails.md")

      assert conn.status == 301
      assert redirected_to(conn, 301) == "/tags/ruby_on_rails.md"
    end

    test "the canonical page names its aliases", ctx do
      html = ctx.conn |> get(~p"/tags/#{ctx.canonical}") |> html_response(200)

      # A reader who arrived via the other spelling has to be able to see where
      # they ended up.
      assert html =~ "rubyonrails"
      assert html =~ ~s(data-tag-aliases)
    end

    test "the German page says it in German", ctx do
      # vutuv is a German site, and an English-only check would not have caught
      # a missing or fuzzy-filled translation of this label.
      html =
        ctx.conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/tags/#{ctx.canonical}")
        |> html_response(200)

      assert html =~ "Auch bekannt als"
    end

    test "the agent siblings carry the alternative names too", ctx do
      md = ctx.conn |> get("/tags/ruby_on_rails.md") |> response(200)
      txt = ctx.conn |> get("/tags/ruby_on_rails.txt") |> response(200)
      json = ctx.conn |> get("/tags/ruby_on_rails.json") |> response(200) |> Jason.decode!()

      assert md =~ "rubyonrails"
      assert txt =~ "rubyonrails"
      assert json["also_known_as"] == ["rubyonrails"]
    end

    test "the tag directory lists the topic once", ctx do
      html = ctx.conn |> get(~p"/tags") |> html_response(200)

      assert html =~ "Ruby on Rails"
      refute html =~ ~s(href="/tags/rubyonrails")
    end
  end

  # Issue #877: the "Add this tag" button was removed from the public tag page.
  # "Add this tag" was ambiguous ("create/define this tag" vs "add it to my
  # profile" — it misled the #844 reporter into a 404), redundant with the
  # /settings/tags editor, and out of step with vutuv's showcase pages, which
  # carry no profile-mutating controls. Adding a tag now lives only in
  # /settings/tags (+ the profile Tags card), so the tag page is pure discovery.
  describe "the tag page carries no profile-mutation control (issue #877)" do
    test "a logged-in visitor without the tag sees no \"Add this tag\" button", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      tag = insert(:tag)

      html = conn |> get(~p"/tags/#{tag}") |> html_response(200)

      refute html =~ "Add this tag"
      refute html =~ ~s(data-to="/settings/tags?tag_param)
    end
  end
end
