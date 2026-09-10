defmodule VutuvWeb.ExternalTagCardsTest do
  @moduledoc """
  What a followed tag's other servers look like once they reach a reader (issue
  #2127): an ordinary card in the feed, the same card filling a tag page's
  fediverse tab, and the report that takes our copy away.

  The one thing these cards exist to get right is that **the server we asked is
  not the author's home**, so the assertions below are mostly about which of two
  hostnames stands where. A card that got them the other way round would tell
  every reader that everybody writing about a topic lives on whichever server
  their neighbour happened to name.

  `async: false`: the module holds `:fetch_external_tag_posts` down, which
  `Vutuv.Tags.ExternalPosts.enabled?/0` and the supervision tree both read.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.ExternalTagHelpers
  import Vutuv.MastodonHelpers, only: [mastodon_conn: 2, mastodon_token: 2]

  alias Vutuv.Repo
  alias Vutuv.Tags.ExternalPost

  # The two hostnames the fixtures use — deliberately different everywhere but
  # in the one test about them being the same.
  @source Vutuv.ExternalTagHelpers.tag_source()
  @author_host Vutuv.ExternalTagHelpers.author_host()

  setup do
    put_config(:fetch_external_tag_posts, true)
    :ok
  end

  defp followed_tag(user, source \\ @source) do
    tag = insert(:tag)
    follow_tag_through(user, tag, source)
    tag
  end

  defp found_post(tag, attrs \\ []) do
    defaults = [source: @source, author_host: @author_host, text: "EIN FUND VON DRUEBEN"]
    external_post(tag, Keyword.merge(defaults, attrs))
  end

  describe "the feed" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "the card stands in the feed like any other post", %{conn: conn, user: user} do
      tag = followed_tag(user)
      post = found_post(tag)

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "EIN FUND VON DRUEBEN"
      assert html =~ ~s(data-external-post="#{post.id}")
    end

    test "the header names the author's server and the quiet line ours", %{
      conn: conn,
      user: user
    } do
      tag = followed_tag(user)
      found_post(tag)

      {:ok, _view, html} = live(conn, ~p"/feed")

      # The chip under the name is the AUTHOR's host…
      assert html =~ ~s(data-remote-network="#{@author_host}")
      refute html =~ ~s(data-remote-network="#{@source}")

      # …and the server we read it from is the small line, and only that.
      assert html =~ ~s(data-external-source="#{@source}")
      assert html =~ "Ada Lovelace"
      assert html =~ "@ada@#{@author_host}"
    end

    test "the line is there even when the two servers are the same", %{conn: conn, user: user} do
      tag = followed_tag(user, @author_host)

      found_post(tag,
        source: @author_host,
        author_host: @author_host,
        author_acct: "ada",
        text: "VOM SERVER SELBST"
      )

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "VOM SERVER SELBST"
      assert html =~ ~s(data-external-source="#{@author_host}")
    end

    test "the card leads to the original and offers no page of ours", %{conn: conn, user: user} do
      tag = followed_tag(user)
      post = found_post(tag)

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ post.url
      refute html =~ "data-remote-permalink"
    end

    test "reporting it empties our copy and takes the row away", %{conn: conn, user: user} do
      tag = followed_tag(user)
      post = found_post(tag)

      {:ok, view, _html} = live(conn, ~p"/feed")

      html =
        view
        |> element(~s([data-external-post="#{post.id}"] [phx-click="report-external-post"]))
        |> render_click()

      refute html =~ "EIN FUND VON DRUEBEN"
      assert Repo.get!(ExternalPost, post.id).reported_at

      # And a fresh page does not bring it back.
      {:ok, _view, again} = live(conn, ~p"/feed")
      refute again =~ "EIN FUND VON DRUEBEN"
    end

    # This card offers no Translate control and the table holds no translation
    # for it — but the page hands its whole subject list to the translation
    # sweep, which keys every entry by kind. A kind that module has no column
    # for raises there rather than being skipped, so with translate mode on the
    # feed went down on mount for anybody whose page held one of these.
    test "a reader with translate mode on still gets their feed", %{conn: conn, user: user} do
      tag = followed_tag(user)
      found_post(tag, language: "fr", text: "UN MESSAGE VENU D AILLEURS")

      {:ok, _user} =
        Vutuv.Accounts.update_user(user, %{
          "feed_languages" => ["de"],
          "feed_foreign_posts" => "translate"
        })

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ "UN MESSAGE VENU D AILLEURS"
    end

    test "a hidden word folds it into the placeholder", %{conn: conn, user: user} do
      tag = followed_tag(user)
      found_post(tag, text: "Alles ueber Krypto, den ganzen Tag")

      {:ok, _filter} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "Krypto"})

      {:ok, _view, html} = live(conn, ~p"/feed")

      refute html =~ "Alles ueber Krypto"
      assert html =~ "Krypto"
    end
  end

  describe "the tag page" do
    # A tag somebody here follows through a server — the page is public, so who
    # that somebody is never matters again.
    setup do
      {:ok, tag: followed_tag(insert(:activated_user))}
    end

    test "its fediverse tab fills with what the other servers carry", %{conn: conn, tag: tag} do
      found_post(tag, text: "WAS AUF DER TAGSEITE STEHT")

      html = conn |> get(~p"/tags/#{tag.slug}?source=fediverse") |> html_response(200)

      assert html =~ "WAS AUF DER TAGSEITE STEHT"
      assert html =~ ~s(data-remote-network="#{@author_host}")
    end

    test "the vutuv tab does not", %{conn: conn, tag: tag} do
      found_post(tag, text: "NUR VON DRUEBEN")

      html = conn |> get(~p"/tags/#{tag.slug}?source=vutuv") |> html_response(200)

      refute html =~ "NUR VON DRUEBEN"
    end

    test "the agent formats carry it too", %{conn: conn, tag: tag} do
      found_post(tag, text: "AUCH FUER AGENTEN")

      body = conn |> get("/tags/#{tag.slug}.md") |> response(200)
      assert body =~ "AUCH FUER AGENTEN"

      json = conn |> get("/tags/#{tag.slug}.json") |> json_response(200)
      entry = Enum.find(json["posts"], &(&1["excerpt"] =~ "AUCH FUER AGENTEN"))

      assert entry["account"] == "@ada@#{@author_host}"
      assert entry["found_via"] == @source
    end

    # Enforced by the purge a block runs (`Vutuv.Fediverse.purge_instance/1`),
    # not by a clause on the read — see `ExternalPosts.showable_query/0`.
    test "a blocked server's post is on no public page", %{conn: conn, tag: tag} do
      found_post(tag, text: "VON EINEM GESPERRTEN SERVER")

      admin = insert(:activated_user)
      {:ok, {_blocked, _purged}} = Vutuv.Fediverse.block_instance(%{"host" => @source}, admin)

      html = conn |> get(~p"/tags/#{tag.slug}?source=fediverse") |> html_response(200)

      refute html =~ "VON EINEM GESPERRTEN SERVER"
    end
  end

  # A Mastodon `Status` is an `Account` object with words attached, and this
  # installation holds no account row for an author it read off a stranger's
  # public timeline. So these rows are dropped there rather than rendered with
  # an invented identity — but dropped, not fallen through: without the reject
  # both endpoints answer 500 with an HTML body to a client that decodes every
  # answer as JSON.
  describe "the Mastodon API" do
    test "leaves these rows out instead of falling over them", %{conn: conn} do
      {_conn, me} = create_and_login_user(conn)
      tag = followed_tag(me)
      found_post(tag, text: "NICHT FUER MASTODON-CLIENTS")

      token = mastodon_token(me, ["read"])

      home = build_conn() |> mastodon_conn(token) |> get("/api/v1/timelines/home")
      assert json_response(home, 200)
      refute home.resp_body =~ "NICHT FUER MASTODON-CLIENTS"

      hashtag =
        build_conn() |> mastodon_conn(token) |> get("/api/v1/timelines/tag/#{tag.slug}")

      assert json_response(hashtag, 200)
      refute hashtag.resp_body =~ "NICHT FUER MASTODON-CLIENTS"
    end
  end

  describe "German" do
    test "the card's own words are translated", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = followed_tag(user)
      found_post(tag)

      {:ok, _view, html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> live(~p"/feed")

      # The quiet provenance line, in German, naming the server we asked.
      assert html =~ "Gefunden über #{@source}"
    end
  end
end
