defmodule VutuvWeb.RemoteActorCardTest do
  @moduledoc """
  The card behind a `@user@host` mention in a post: who may open it, what it
  answers, and the follow round trip inside it
  (`VutuvWeb.RemoteActorCardController`).
  """
  # `async: false`: every test here stubs the Fediverse HTTP client through
  # `Application.put_env/3`, which is global and outlives no transaction.
  use VutuvWeb.ConnCase, async: false

  import Vutuv.FediverseHelpers
  import Vutuv.MastodonHelpers, only: [cached_post: 2]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias VutuvWeb.RemoteActorCardHTML

  @actor "https://social.example/users/them"
  @address "them@social.example"

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "social.example",
      handle: "them",
      name: "Them Themself",
      summary: "Schreibt über Züge.",
      inbox_uri: @actor <> "/inbox"
    })
  end

  defp federating(conn) do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    {conn, user}
  end

  # A remote server that answers the actor document and nothing else. Any other
  # request is a request this card should not be making.
  defp serve_actor do
    stub_remote(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => @actor,
          "type" => "Person",
          "preferredUsername" => "them",
          "name" => "Them Themself",
          "inbox" => @actor <> "/inbox",
          "publicKey" => %{"id" => @actor <> "#main-key", "publicKeyPem" => "PEM"}
        })
      )
    end)
  end

  test "a visitor who is not signed in gets no card", %{conn: conn} do
    account()

    conn = post(conn, ~p"/system/fediverse/actor_card", address: @address)

    assert conn.status == 404
  end

  # The card may resolve an address this installation has never seen, which is
  # an outbound request to a host somebody else named in a post. As a GET that
  # would be a link, and a link is followed by prefetches and crawlers.
  test "there is no GET surface at all", %{conn: conn} do
    {conn, _user} = federating(conn)

    conn = get(conn, "/system/fediverse/actor_card?address=#{@address}")

    assert conn.status == 404
  end

  test "it names the account, offers the follow and keeps both ways onward", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "Them Themself"
    assert html =~ "@them@social.example"
    assert html =~ "Schreibt über Züge."
    assert html =~ ~s(data-actor-act="follow")
    # Their page here, and the original out there: a reader who does not want to
    # follow is never left in a box with one button.
    assert html =~ ~p"/system/fediverse/account/#{acc.id}"
    assert html =~ @actor
  end

  # The common case, and the reason the card is cheap: most accounts a member
  # meets in a post are already stored, because somebody here follows them or
  # something of theirs arrived. Calibrated by the stub, which fails the test if
  # any request goes out at all.
  test "an account we already hold costs no request", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    stub_remote(fn _conn -> raise "an account we already hold must not be fetched" end)

    assert post(conn, ~p"/system/fediverse/actor_card", address: @address)
           |> html_response(200) =~ "Them Themself"
  end

  test "the follow starts as requested and is taken back from the same card", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()
    serve_actor()

    html =
      post(conn, ~p"/system/fediverse/actor_card/follow", address: @address)
      |> html_response(200)

    # "Requested", not "Following": that server has not answered yet, and a card
    # that said otherwise would be a lie the member acts on.
    assert html =~ ~s(data-follow-state="requested")
    assert html =~ ~s(data-actor-act="unfollow")
    assert Repo.aggregate(Follow, :count) == 1

    html =
      conn
      |> delete(~p"/system/fediverse/actor_card/follow", address: @address)
      |> html_response(200)

    assert html =~ ~s(data-actor-act="follow")
    assert Repo.aggregate(Follow, :count) == 0
  end

  # Real visitors here send `Accept-Language: de`, and `Phoenix.ConnTest`
  # defaults to English — so the German render is its own case. Every word on
  # this card is an existing msgid rather than a new one (the same sentences the
  # account page and a looked-up post's card already say), and this is what
  # holds that: a new msgid would come back fuzzy-filled and read as confident
  # nonsense in German while every English assertion above stayed green.
  test "it reads German for a German reader", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    html =
      conn
      # The login already sent a response on this conn; a header goes on the
      # recycled one.
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> post(~p"/system/fediverse/actor_card", address: @address)
      |> html_response(200)

    assert html =~ "Anderes Netzwerk"
    assert html =~ "Folgen"
    assert html =~ "Kontoseite hier"
    assert html =~ "Original ansehen"
  end

  # The one way off this site, and it used to say only that it was one. A reader
  # about to leave for somebody else's server reads the address first, the way
  # they would read a browser's status bar — and here that address is not
  # guessable from the card, since an actor URI need not be spelled like the
  # `@user@host` above it (`/users/them`, `/u/them`, `/profile/them`).
  #
  # On a line of its own since the address in the sentence wrapped the row onto
  # three lines and made the quietest half of the card its tallest block.
  test "the way out names where it goes", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "View the original"

    assert html =~
             ~s(<span class="actor-card__link-address">social.example/users/them</span>)

    # And the address is only ever a label: the href stays the whole URL.
    assert html =~ @actor
  end

  # A scheme and a `www.` are noise every reader already knows, and dropping
  # them leaves the two parts a reader actually checks: which server, and whose
  # account on it.
  #
  # `HTTPS://` is not a curiosity here: this string is a remote server's, not
  # ours, and a scheme left standing would spend eight characters saying that a
  # link is a link.
  test "an ordinary actor address reaches the card whole, without scheme or www" do
    assert RemoteActorCardHTML.origin_address("https://social.heise.de/users/heiseonline") ==
             "social.heise.de/users/heiseonline"

    assert RemoteActorCardHTML.origin_address("HTTPS://www.chaos.social/@feed/") ==
             "chaos.social/@feed"
  end

  # Nothing cuts the address here any more: it arrives whole and the browser
  # ends it where the card ends (`text-overflow: ellipsis` on its own line). It
  # used to be pre-cut at 40 characters, a number measured against the sentence
  # it was embedded in, and a count guessing at a width is wrong on the next
  # screen. Cutting is still only ever from the END, which is the property this
  # pins: the host leads the string and is the fact it is carrying.
  test "a long address arrives whole, host first, for the browser to cut" do
    address =
      RemoteActorCardHTML.origin_address(
        "https://www.example.social/users/a-very-long-handle-indeed"
      )

    assert address == "example.social/users/a-very-long-handle-indeed"
  end

  test "a member without a Fediverse identity is told why, not shown a dead button", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ ~s(data-actor-act="follow")
    assert html =~ ~s(data-actor-card-error)
    assert html =~ "Fediverse"
  end

  # The fragment lands on a `<body>`-level node outside every LiveView root, so
  # two things in it would be quietly broken: a `<.link navigate>` (LiveView
  # binds those to an owning view, and there is none) and a fixed `id` (the card
  # can be open over a page that already renders the same element — the account
  # page renders the refusal panel this card deliberately does not). Hence
  # `follow_refusal_sentence/1` instead of `follow_refusal_panel/1`, and hence
  # this test, which is the only thing standing between the next author and a
  # dead link nobody notices.
  test "carries no live-navigation link and no id anybody else could own", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ "data-phx-link"
    refute html =~ ~s(id=)
  end

  # A fragment, not a page: both layouts are off. With only `put_layout` off the
  # `:browser` pipeline's root layout still wrapped every card in a whole HTML
  # document, and `innerHTML` unwraps that into the panel — 22 meta tags, six
  # stylesheet links and two scripts, re-fetched on every open, none of which a
  # substring assertion on the card's own words would ever notice.
  test "the answer is a fragment, not a document", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ "<html"
    refute html =~ "<meta"
    refute html =~ "<script"
    assert html =~ ~s(class="actor-card__content")
  end

  test "an address nobody can resolve still says why, and still leads out", %{conn: conn} do
    {conn, _user} = federating(conn)

    stub_remote(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    html =
      post(conn, ~p"/system/fediverse/actor_card", address: "nobody@social.example")
      |> html_response(200)

    assert html =~ ~s(data-actor-card-error)
    assert html =~ "https://social.example/@nobody"
    refute html =~ ~s(data-actor-act="follow")
  end

  # ── What the card knows beyond the account's own words ────────────────────
  #
  # A self-description is what an account says about itself and settles nothing:
  # every account claims to be worth reading. What it last wrote, and how much
  # of it we hold, is the reader's actual evidence — so the card carries a count
  # line and the newest few posts, and the description shrinks to make room.

  test "it says how much of the account we hold and quotes the newest post", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    cached_post(acc,
      content_text: "Der ältere.",
      published_at: DateTime.add(DateTime.utc_now(:second), -3600)
    )

    cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "2 posts here"
    assert html =~ "Ein Zug fährt durch die Nacht."
    # The older one comes along, folded away behind the expander: the card is
    # the reader deciding whether to follow, and one post is a poor sample.
    assert html =~ "Der ältere."
    assert html =~ ~s(data-actor-more-posts)
  end

  # Only one post to show, so there is nothing to expand — a control that opens
  # an empty drawer is worse than no control.
  test "a single post grows no expander", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "Ein Zug fährt durch die Nacht."
    refute html =~ ~s(data-actor-more-posts)
  end

  # The card opens over a post the reader is already looking at, and quoting
  # that very post back at them under "Latest here" spends the card's most
  # valuable line saying what is on the screen behind it. The one below moves
  # up; the count and the clock stay the account's.
  test "the post the reader has open is not quoted back at them", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    cached_post(acc,
      content_text: "Der ältere.",
      published_at: DateTime.add(DateTime.utc_now(:second), -3600)
    )

    open = cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html =
      post(conn, ~p"/system/fediverse/actor_card", address: @address, context: open.id)
      |> html_response(200)

    assert html =~ "2 posts here"
    refute html =~ "Ein Zug fährt durch die Nacht."
    assert html =~ "Der ältere."
  end

  # The one post we hold is the one behind the card: nothing left to quote, and
  # the count line stays, because we do hold it.
  test "a context that leaves nothing to quote leaves the count standing", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    open = cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html =
      post(conn, ~p"/system/fediverse/actor_card", address: @address, context: open.id)
      |> html_response(200)

    assert html =~ "1 post here"
    refute html =~ ~s(data-actor-card-latest)
  end

  # The drawer is the other thing the reader has in front of them, and every act
  # replaces the whole fragment — so without the flag travelling back, opening
  # the older posts and then pressing Follow folds them away again.
  test "an opened drawer is still open after a follow", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()
    serve_actor()

    cached_post(acc,
      content_text: "Der ältere.",
      published_at: DateTime.add(DateTime.utc_now(:second), -3600)
    )

    cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html =
      post(conn, ~p"/system/fediverse/actor_card", address: @address)
      |> html_response(200)

    assert html =~ ~s(data-actor-more-posts hidden)

    html =
      post(conn, ~p"/system/fediverse/actor_card/follow", address: @address, expanded: "1")
      |> html_response(200)

    refute html =~ ~s(data-actor-more-posts hidden)
    assert html =~ "is-open"
  end

  # The context rides along with every act, not only with the open: pressing
  # Follow re-renders the whole card, and a quote that appears on that press is
  # the card contradicting itself over one click.
  test "the context survives a follow", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()
    serve_actor()

    open = cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html =
      post(conn, ~p"/system/fediverse/actor_card/follow", address: @address, context: open.id)
      |> html_response(200)

    refute html =~ "Ein Zug fährt durch die Nacht."
  end

  # An account we hold nothing from must not grow an empty row saying so: "0
  # posts here" is noise on a card this small, and the reader can see the same
  # thing by opening the account page.
  test "an account we hold nothing from grows no count line", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ "posts here"
    refute html =~ ~s(data-actor-card-latest)
  end

  # The preview is a second surface showing a post, so it obeys the reader's
  # filters like the first one. Without the `ContentFilters` call in
  # `RemoteActorCardController.preview/2` this quotes the muted word straight at
  # the member who muted it — and the count line stays, which is the honest
  # half: we hold the post, they just do not want to read it here.
  test "a post the reader filtered away is not quoted at them", %{conn: conn} do
    {conn, user} = federating(conn)
    acc = account()

    {:ok, _filter} =
      Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "Krypto"})

    cached_post(acc, content_text: "Alles über Krypto.")

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "1 post here"
    refute html =~ "Alles über Krypto."
    refute html =~ ~s(data-actor-card-latest)
  end

  # The reader's second pass over a post, beside their filters: their own
  # search-and-replace rules for this author (`Vutuv.PostRewrites`). The card is
  # the fourth surface over these rows and was the only one skipping them, so a
  # member who deletes a mirror's footer everywhere else read it here — and the
  # filter below judged the text before the rule had run, which is the order
  # `PostTeaser.record_line/4` exists to fix.
  test "a quote is rewritten by the reader's rules for that account", %{conn: conn} do
    {conn, user} = federating(conn)
    acc = account()

    {:ok, _rule} =
      Vutuv.PostRewrites.create_rule(user, "@them@social.example", %{
        pattern: " -- Gepostet über einen Bot"
      })

    cached_post(acc, content_text: "Ein Zug fährt durch die Nacht. -- Gepostet über einen Bot")

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "Ein Zug fährt durch die Nacht."
    refute html =~ "Gepostet über einen Bot"
  end

  # A post with nothing written on it — a photograph and no caption — has no
  # line to be, and `PostTeaser.line/2` answers `""` rather than nil for it. A
  # gate testing for nil lets it through, and it then spends one of the card's
  # four quote slots on an empty box.
  test "a post with no words at all is not quoted as an empty line", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    # `""` and not nil: the helper's `attrs[:content_text] || "Von woanders."`
    # would fill a nil in, and both spellings reach the gate the same way —
    # `Posts.text/1` hands `line/2` an empty binary either way.
    cached_post(acc,
      content_text: "",
      published_at: DateTime.add(DateTime.utc_now(:second), -60)
    )

    cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "2 posts here"
    assert html =~ "Ein Zug fährt durch die Nacht."
    # The wordless one would have been the only thing behind the expander.
    refute html =~ ~s(data-actor-more-posts)
  end

  # A content warning is the author asking for a click before their words are
  # read. A preview line that ignores it puts them on screen unasked.
  test "a post its author marked sensitive is not quoted either", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()

    cached_post(acc, content_text: "Das will nicht jeder sehen.", sensitive: true)

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    assert html =~ "1 post here"
    refute html =~ "Das will nicht jeder sehen."
  end

  # ── Muting, from the card ─────────────────────────────────────────────────

  test "the account can be muted and unmuted without leaving the card", %{conn: conn} do
    {conn, user} = federating(conn)
    acc = account()
    serve_actor()

    post(conn, ~p"/system/fediverse/actor_card/follow", address: @address)

    html =
      conn
      |> post(~p"/system/fediverse/actor_card/mute", address: @address, scope: "account")
      |> html_response(200)

    assert Repo.get_by!(Follow, user_id: user.id, remote_account_id: acc.id).muted
    # The way back out is on the card that comes back, or a mute is a one-way door.
    assert html =~ "Unmute"

    conn
    |> post(~p"/system/fediverse/actor_card/mute", address: @address, scope: "account")
    |> html_response(200)

    refute Repo.get_by!(Follow, user_id: user.id, remote_account_id: acc.id).muted
  end

  # Muting the account is only offered where there is a follow to mute:
  # `set_remote_follow_mute/3` scopes to the member's own row and answers `:ok`
  # for a row that is not there, so an offer without a follow is a control that
  # visibly does nothing.
  test "muting the account is not offered to somebody who does not follow it", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()

    html = post(conn, ~p"/system/fediverse/actor_card", address: @address) |> html_response(200)

    refute html =~ ~s(data-actor-act="mute-account")
    # The server can always be muted — that lever is the member's own feed
    # setting and needs no relationship with anybody on it.
    assert html =~ ~s(data-actor-act="mute-host")
  end

  # The muted-server list is a column on the *member*, so the viewer this
  # request loaded is one write out of date the moment the mute lands — unlike
  # the follow states, which `card/4` re-reads from the database. Without
  # `mute/2` putting the act's answer back into the conn, the card that comes
  # back still offers "Mute social.example" on a server that is now muted, and
  # the press reads as having done nothing. Found in a browser, not by a test.
  test "the whole server can be muted from the card, and says so on the way back",
       %{conn: conn} do
    {conn, user} = federating(conn)
    account()

    html =
      conn
      |> post(~p"/system/fediverse/actor_card/mute", address: @address, scope: "host")
      |> html_response(200)

    assert "social.example" in Vutuv.Fediverse.muted_hosts(Repo.reload!(user))
    assert html =~ "Unmute social.example"
    refute html =~ "Mute social.example"

    html =
      conn
      |> post(~p"/system/fediverse/actor_card/mute", address: @address, scope: "host")
      |> html_response(200)

    assert Vutuv.Fediverse.muted_hosts(Repo.reload!(user)) == []
    assert html =~ "Mute social.example"
  end

  test "a scope nobody offered mutes nothing", %{conn: conn} do
    {conn, user} = federating(conn)
    account()

    assert post(conn, ~p"/system/fediverse/actor_card/mute", address: @address, scope: "wat")
           |> html_response(200)

    assert Vutuv.Fediverse.muted_hosts(Repo.reload!(user)) == []
  end

  # ── The phone ─────────────────────────────────────────────────────────────
  #
  # One fragment serves both shapes: the popover under the word and the sheet at
  # the bottom of a phone. What differs is CSS, except the one thing CSS cannot
  # do — on a touch screen there is no hover, so the follow button's "are you
  # sure" step has to travel with the fragment as a translated string, as a
  # third pre-rendered label CSS picks between. `mention_card.js` arms by adding
  # a class and never writes a word.
  test "the follow button carries all three of its labels", %{conn: conn} do
    {conn, _user} = federating(conn)
    account()
    serve_actor()

    html =
      post(conn, ~p"/system/fediverse/actor_card/follow", address: @address)
      |> html_response(200)

    assert html =~ ~s(data-actor-state-on)
    assert html =~ ~s(data-actor-state-off)
    assert html =~ ~s(data-actor-state-confirm)
    assert html =~ "Really withdraw?"
  end

  test "the German reader gets the new lines in German too", %{conn: conn} do
    {conn, _user} = federating(conn)
    acc = account()
    cached_post(acc, content_text: "Ein Zug fährt durch die Nacht.")

    html =
      conn
      |> recycle()
      |> put_req_header("accept-language", "de-DE,de")
      |> post(~p"/system/fediverse/actor_card", address: @address)
      |> html_response(200)

    assert html =~ "1 Beitrag hier"
    assert html =~ "Zuletzt hier"
    assert html =~ "Adresse kopieren"
    assert html =~ "social.example stummschalten"
  end
end
