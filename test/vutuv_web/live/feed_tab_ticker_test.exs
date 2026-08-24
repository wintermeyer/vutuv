defmodule VutuvWeb.FeedTabTickerTest do
  @moduledoc """
  The quote beside the source tab you are not reading (issue #1668).

  The dot from #1503 says *that* something landed over there; the ticker says
  *what*, for a few seconds. What is worth testing is not that it renders but
  the rules that keep it from becoming a nuisance: one quote per window, a
  count instead of a second quote, a window that ends on its own (and not by a
  later patch putting it back), a silence afterwards — and no quote at all into
  a browser still running the previous release's stylesheet and hooks.

  Not async: one test sets `:feed_ticker_cooldown_ms`, which is application env
  — process state the SQL sandbox does not roll back, and every open feed reads
  it. `config/test.exs` holds it at 0 so the other tests here can fire twice.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    # `record_remote_post/2` claims the shared inbound cap, which lives in the
    # RateLimiter's ETS table and outlives a test.
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  # A member here the viewer follows. Kept apart from posting on purpose: once
  # the feed is open, every post by a followed author IS an arrival, so a
  # helper that posts while setting up would spend the window under test.
  defp followed_author(viewer, attrs \\ []) do
    author = insert(:user, [email_confirmed?: true] ++ attrs)
    Social.follow(viewer, author.id)
    author
  end

  defp followed_post(viewer, body) do
    author = followed_author(viewer)
    {:ok, post} = Posts.create_post(author, %{body: body})
    {author, post}
  end

  defp remote_account(user, handle) do
    actor = "https://social.example/users/#{handle}"

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: actor,
        host: "social.example",
        handle: handle,
        name: String.capitalize(handle),
        inbox_uri: actor <> "/inbox"
      })

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{handle}"
    })

    account
  end

  defp cached_post(account, body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    Repo.insert!(%Vutuv.Fediverse.RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/posts/#{unique}",
      origin_url: "https://social.example/@them/#{unique}",
      content_text: body,
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  defp remote_note(account, text) do
    unique = System.unique_integer([:positive])

    %{
      "type" => "Create",
      "actor" => account.actor_uri,
      "object" => %{
        "id" => "https://social.example/posts/#{unique}",
        "type" => "Note",
        "attributedTo" => account.actor_uri,
        "content" => "<p>#{text}</p>",
        "url" => "https://social.example/@#{account.handle}/#{unique}",
        "published" => DateTime.to_iso8601(DateTime.utc_now(:second)),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    }
  end

  # The reader on one named tab, with the other one populated so the tab bar
  # exists at all (`Posts.fediverse_feed_available?/1` asks the sources).
  # `connect_params` is what the browser sends on join — the stale-assets test
  # below puts a `_track_static` in there.
  defp reader_on(conn, tab, connect_params \\ %{}) do
    {conn, user} = create_and_login_user(conn)
    {_author, _post} = followed_post(user, "an older post")
    account = remote_account(user, "them")
    cached_post(account, "written out there")

    # `get/2` recycles a conn that has already been sent, and recycling drops
    # `private` — connect params included. Recycling here, before they are put,
    # is what gets them as far as the join.
    {:ok, view, _html} =
      conn |> recycle() |> put_connect_params(connect_params) |> live(~p"/feed")

    render_click(view, "filter-source", %{"type" => tab})

    %{view: view, user: user, account: account}
  end

  # The quote's own markup, or nil when no window is open. Floki is not a
  # dependency here, so the three readers below work on the element's HTML.
  defp ticker(view) do
    if has_element?(view, "#feed-tab-ticker") do
      view |> element("#feed-tab-ticker") |> render()
    end
  end

  defp ticker_text(view) do
    case ticker(view) do
      nil ->
        nil

      html ->
        html
        |> String.replace(~r/<[^>]*>/, " ")
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()
    end
  end

  defp ticker_attr(view, name) do
    case ticker(view) do
      nil ->
        nil

      html ->
        case Regex.run(~r/#{name}="([^"]*)"/, html) do
          [_, value] -> value
          _ -> nil
        end
    end
  end

  defp window_id(view), do: ticker_attr(view, "data-ticker-window")

  defp dotted?(view, tab) do
    has_element?(view, "#feed-source-tabs [data-filter-tab='#{tab}'] [data-post-filter-unseen]")
  end

  describe "a post landing on the other tab" do
    test "is quoted there, by author and first words", %{conn: conn} do
      %{view: view, user: user} = reader_on(conn, "fediverse")
      author = followed_author(user, username: "quotable")

      {:ok, _post} =
        Posts.create_post(author, %{body: "Frisch geflasht, **unter zwei Sekunden**"})

      quote_line = ticker_text(view)
      assert quote_line =~ "@quotable"
      # The body arrives as one line of plain text: no Markdown, no asterisks.
      assert quote_line =~ "Frisch geflasht, unter zwei Sekunden"
      # The dot is a separate promise and is made too.
      assert dotted?(view, "vutuv")
    end

    test "carries the tab it names, so a click switches to it", %{conn: conn} do
      %{view: view, user: user} = reader_on(conn, "fediverse")
      author = followed_author(user)
      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})

      assert ticker(view)
      assert view |> element("#feed-tab-ticker") |> render_click()

      assert has_element?(view, "[data-filter-tab='vutuv'][aria-pressed='true']")
      # Going there is what the quote was for, so it goes with the dot.
      refute ticker(view)
      refute dotted?(view, "vutuv")
    end

    test "names a remote author without their server", %{conn: conn} do
      %{view: view, account: account} = reader_on(conn, "vutuv")

      assert :ok =
               Fediverse.record_remote_post(
                 remote_note(account, "frisch von drüben"),
                 account.actor_uri
               )

      quote_line = ticker_text(view)
      # "@them", not "@them@social.example": the tab beside it already says
      # Fediverse, and the domain would take half the line.
      assert quote_line =~ "@them"
      refute quote_line =~ "social.example"
      assert quote_line =~ "frisch von drüben"
    end
  end

  describe "more than one inside the window" do
    test "the quote gives up and becomes a count, on the same clock", %{conn: conn} do
      %{view: view, user: user} = reader_on(conn, "fediverse")
      author = followed_author(user)

      {:ok, _first} = Posts.create_post(author, %{body: "der erste"})
      assert ticker_text(view) =~ "der erste"
      opened = window_id(view)

      {:ok, _second} = Posts.create_post(author, %{body: "der zweite"})
      {:ok, _third} = Posts.create_post(author, %{body: "der dritte"})

      counted = ticker_text(view)
      assert counted =~ "3"
      # Neither post is quoted any more: one line cannot stand for three.
      refute counted =~ "der erste"
      refute counted =~ "der dritte"

      # Calibrated against the tempting version that re-opens on every arrival:
      # the window id is what the browser's clock keys on, so a new one here
      # would hand a busy source the bar for as long as it keeps posting.
      assert window_id(view) == opened
    end
  end

  describe "the end of a window" do
    test "the browser's report clears it and leaves the dot", %{conn: conn} do
      %{view: view, user: user} = reader_on(conn, "fediverse")
      author = followed_author(user)
      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})
      assert ticker(view)

      render_hook(view, "hide-tab-ticker", %{})

      refute ticker(view)
      # The quote was the loud half. The dot is the standing one.
      assert dotted?(view, "vutuv")
    end

    test "a silence follows it, and the arrival inside gets only its dot", %{conn: conn} do
      put_config(:feed_ticker_cooldown_ms, 60_000)

      %{view: view, user: user} = reader_on(conn, "fediverse")
      author = followed_author(user)

      {:ok, _first} = Posts.create_post(author, %{body: "der erste"})
      render_hook(view, "hide-tab-ticker", %{})

      {:ok, _second} = Posts.create_post(author, %{body: "der zweite"})

      refute ticker(view)
      assert dotted?(view, "vutuv")
    end
  end

  describe "the member's own choice" do
    test "switched off, the tab says no more than it did before", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, user} = Vutuv.Accounts.update_user(user, %{"feed_tab_ticker?" => false})

      {author, _post} = followed_post(user, "an older post")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})

      refute ticker(view)
      assert dotted?(view, "vutuv")
    end

    test "the window length is the member's, not a constant", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, user} = Vutuv.Accounts.update_user(user, %{"feed_tab_ticker_seconds" => 20})

      {author, _post} = followed_post(user, "an older post")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})
      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})

      assert ticker_attr(view, "data-ticker-seconds") == "20"
    end
  end

  describe "a muted word" do
    test "is not quoted into the bar it was muted out of", %{conn: conn} do
      # Calibrated against the version without the filter check: `decorate/3`
      # stamps `:filtered_by` only on the branch for the tab the reader IS on,
      # so a quote built straight off the body would put the muted word into
      # the bar — the one place the member cannot scroll past it.
      {conn, user} = create_and_login_user(conn)

      {:ok, _filter} =
        Vutuv.ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "krypto"})

      {author, _post} = followed_post(user, "an older post")
      account = remote_account(user, "them")
      cached_post(account, "written out there")

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "filter-source", %{"type" => "fediverse"})

      {:ok, _post} = Posts.create_post(author, %{body: "Alles über Krypto und so"})

      refute ticker(view)
      # Still worth a dot: something did land over there.
      assert dotted?(view, "vutuv")
    end
  end

  describe "a browser left over from the previous release" do
    # What v7.347.0 looked like on a feed that had been open since before the
    # deploy: the socket reconnects to the new release and patches the quote
    # into a document whose stylesheet has never heard of `.filter-tab-ticker`
    # and whose bundle has no `FeedTicker` hook — so the quote drew as an
    # unstyled 200-character paragraph across the tab bar, and no clock ever
    # took it away. Everything else on that page is older than the browser's
    # copy and survives the patch; the ticker is the half that cannot.
    setup do
      # `static_changed?/1` compares what the client reports against the
      # digest manifest, which only exists in a release. Two entries that
      # cannot match, so the comparison has something to answer with.
      Phoenix.Config.put(VutuvWeb.Endpoint, :cache_static_manifest_latest, %{
        "assets/app.css" => "assets/app-nowdeployed.css"
      })

      on_exit(fn ->
        Phoenix.Config.put(VutuvWeb.Endpoint, :cache_static_manifest_latest, nil)
      end)
    end

    test "gets the dot and no quote", %{conn: conn} do
      %{view: view, user: user} =
        reader_on(conn, "fediverse", %{
          "_track_static" => ["http://localhost/assets/app-fromthelastrelease.css"]
        })

      author = followed_author(user)
      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})

      refute ticker(view)
      assert dotted?(view, "vutuv")
    end

    test "while the browser on this release still gets both", %{conn: conn} do
      # The other half of the gate: with assets the server recognises, the
      # window opens as before. Without this the test above would pass on a
      # ticker that is simply broken.
      %{view: view, user: user} =
        reader_on(conn, "fediverse", %{
          "_track_static" => ["http://localhost/assets/app-nowdeployed.css"]
        })

      author = followed_author(user)
      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})

      assert ticker(view)
      assert dotted?(view, "vutuv")
    end
  end

  describe "the layout the gate reads" do
    test "marks both assets, or the client reports nothing to compare", %{conn: conn} do
      # `phx-track-static` is the whole input to `static_changed?/1`: without
      # it the client sends no manifest, the comparison answers "unchanged"
      # for every browser, and the gate above is dead code.
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ ~r/<link[^>]+phx-track-static[^>]*href="[^"]*app[^"]*\.css/
      assert html =~ ~r/<script[^>]+phx-track-static[^>]*src="[^"]*app[^"]*\.js/
    end
  end
end
