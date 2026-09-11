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

  # A second server this installation asked, for the copies one original leaves
  # behind (issue #2164): the same status read off two servers is two rows, and
  # what relates them needs two hostnames that are not the author's.
  @other_source "social.example"

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

    # The same post read off two servers under two tags is two rows and two
    # cards, and a member who reports one of them has been told the post is
    # gone from this site. It has to be — the reader who then meets the twin
    # under another "Gefunden über" line is watching us break that promise
    # (issue #2164).
    test "reporting the author's own copy takes every copy of that original with it", %{
      conn: conn,
      user: user
    } do
      here = followed_tag(user, @author_host)
      there = followed_tag(user, @other_source)
      url = "https://#{@author_host}/@ada/4711"

      clicked = found_post(here, url: url, source: @author_host)
      twin = found_post(there, url: url, source: @other_source)

      other =
        found_post(here,
          url: "https://#{@author_host}/@ada/4712",
          source: @author_host,
          text: "EIN ZWEITER FUND"
        )

      {:ok, view, html} = live(conn, ~p"/feed")
      assert html =~ ~s(data-external-post="#{twin.id}")

      html =
        view
        |> element(~s([data-external-post="#{clicked.id}"] [phx-click="report-external-post"]))
        |> render_click()

      refute html =~ ~s(data-external-post="#{clicked.id}")
      refute html =~ ~s(data-external-post="#{twin.id}")
      assert html =~ ~s(data-external-post="#{other.id}")

      assert Repo.get!(ExternalPost, twin.id).reported_at

      # And neither of them comes back on a fresh page.
      {:ok, _view, again} = live(conn, ~p"/feed")
      refute again =~ ~s(data-external-post="#{twin.id}")
      assert again =~ "EIN ZWEITER FUND"
    end

    # And the other half of the same promise: a card some other server relayed
    # speaks only for that server, so the copy beside it stays — and the dialog
    # the member read says so before they press it. Any host a member names as
    # a source may claim any address, so a rule that let this card reach the
    # other one would let a planted card blank honest copies of somebody else's
    # post (`8b2c1a862`).
    test "reporting a relayed card leaves the copies other servers filed", %{
      conn: conn,
      user: user
    } do
      here = followed_tag(user)
      there = followed_tag(user, @other_source)
      url = "https://#{@author_host}/@ada/4713"

      clicked = found_post(here, url: url)
      twin = found_post(there, url: url, source: @other_source, text: "DIE ANDERE KOPIE")

      {:ok, view, _html} = live(conn, ~p"/feed")

      html =
        view
        |> element(~s([data-external-post="#{clicked.id}"] [phx-click="report-external-post"]))
        |> render_click()

      refute html =~ ~s(data-external-post="#{clicked.id}")
      assert html =~ ~s(data-external-post="#{twin.id}")
      refute Repo.get!(ExternalPost, twin.id).reported_at
      assert html =~ "DIE ANDERE KOPIE"
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

    # The page must neither take anything down nor fall over. Both report events
    # are pushed, because the guard that answers them lives in the module that
    # owns all six of this menu's events — see `VutuvWeb.Live.RemotePostActions`.
    test "an anonymous reader's socket reports nothing", %{tag: tag} do
      post = found_post(tag, text: "BLEIBT STEHEN")

      {:ok, view, _html} =
        live_isolated(build_conn(), VutuvWeb.TagLive.Timeline,
          session: %{"tag_id" => tag.id, "source" => "fediverse"}
        )

      assert render_click(view, "report-external-post", %{"id" => post.id})
      assert render_click(view, "report-remote-post", %{"id" => post.id})
      refute Repo.get!(ExternalPost, post.id).reported_at
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

    # Dropping the row from the **answer** is not the same as dropping it from
    # the **walk**. The home timeline reads its `Link` boundary off the merged
    # feed's entry ids, before the presenter has rejected anything, so an
    # `external-<uuid>` reaches `Pagination.link_header/4` — and a prefix
    # `bare_id/1` does not know survives into the header, casts to nil on the
    # way back, and a nil boundary is the newest page. The client's walk then
    # restarts at the top forever.
    test "its ids never leave as a boundary a client cannot hand back", %{conn: conn} do
      {_conn, me} = create_and_login_user(conn)
      tag = followed_tag(me)
      for _n <- 1..3, do: found_post(tag)

      token = mastodon_token(me, ["read"])
      answer = build_conn() |> mastodon_conn(token) |> get("/api/v1/timelines/home?limit=3")

      link = answer |> Plug.Conn.get_resp_header("link") |> List.first()

      assert link, "the walk offered no boundary at all"
      refute link =~ "external-"
    end
  end

  describe "German" do
    # A German feed, which is what a real visitor sends
    # (`Accept-Language: de-DE,de`) and what a plain English check never sees.
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      tag = followed_tag(user, @author_host)

      relayed = found_post(followed_tag(user))
      own = found_post(tag, source: @author_host, url: "https://#{@author_host}/@ada/4714")

      {:ok, view, html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> live(~p"/feed")

      {:ok, view: view, html: html, relayed: relayed, own: own}
    end

    test "the card's own words are translated", %{html: html} do
      # The quiet provenance line, in German, naming the server we asked.
      assert html =~ "Gefunden über #{@source}"
    end

    # Both sentences promise the act and nothing about the future: a tombstone
    # keeps the post out of the next pull, but only until `prune/0` drops it
    # with the last follow of that pair. The one they replaced promised a
    # deletion of "unsere Kopie" — singular, and of a row that is blanked rather
    # than deleted — while the copies it did not touch kept standing two cards
    # further down (issue #2164).
    test "the author's own copy promises every copy", %{view: view, html: html, own: own} do
      assert html =~ "Jede Kopie verschwindet sofort für alle auf diesem vutuv."
      refute html =~ "Unsere Kopie wird sofort für alle auf diesem vutuv gelöscht"
      refute html =~ "holen ihn nicht wieder"

      after_click =
        view
        |> element(~s([data-external-post="#{own.id}"] [phx-click="report-external-post"]))
        |> render_click()

      assert after_click =~ "Jede Kopie auf diesem vutuv ist weg."
      refute after_click =~ "kommt nicht wieder"
    end

    # And a relayed card promises only itself, because that is all it may take:
    # a sentence saying "jede Kopie" over a report that leaves the copy beside
    # it standing is this issue's own defect written the other way round.
    test "a relayed copy promises only itself", %{view: view, html: html, relayed: relayed} do
      assert html =~
               "Diese Kopie verschwindet sofort für alle auf diesem vutuv. Kopien von anderen Servern bleiben stehen."

      after_click =
        view
        |> element(~s([data-external-post="#{relayed.id}"] [phx-click="report-external-post"]))
        |> render_click()

      assert after_click =~ "Diese Kopie ist für alle auf diesem vutuv weg."
    end
  end
end
