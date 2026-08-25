defmodule VutuvWeb.BrowserTabTeaserTest do
  @moduledoc """
  The teaser in the browser tab's own title (issue #1681).

  The shell is mounted on every page of every logged-in member and already
  receives every arrival, so what is worth testing is not that a quote renders
  but the rules that keep the feature from turning one popular post into
  thousands of feed queries: nothing is spent on a tab the member is looking
  at, a second arrival inside the window is counted rather than looked up, and
  the silence afterwards is armed even by the arrivals that produce no quote at
  all — the case that would otherwise have no rate limit whatsoever.

  Not async: two tests set `:tab_teaser_cooldown_ms`, which is application env —
  process state the SQL sandbox does not roll back, and every open shell reads
  it. `config/test.exs` holds it at 0 so the other tests here can fire twice.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts
  alias Vutuv.Sessions
  alias Vutuv.Social

  @app_js "assets/js/app.js"

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

  # The shell as one of this member's browser tabs. `hidden?` is what the
  # TabBadge hook reports on connect: the server refuses to spend a lookup
  # until it hears that the member is looking somewhere else.
  defp tab(conn, user, hidden? \\ true) do
    {token, _session} = Sessions.start_session(user, build_conn(), alert: false)

    {:ok, view, _html} =
      live_isolated(conn, VutuvWeb.ShellLive, session: %{"session_token" => token})

    render_hook(view, "tab:visibility", %{"hidden" => hidden?})
    view
  end

  defp followed_author(viewer, attrs \\ []) do
    author = insert(:user, [email_confirmed?: true] ++ attrs)
    Social.follow(viewer, author.id)
    author
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

  describe "a post arriving while the member is somewhere else" do
    test "pages its author and first words through the title", %{conn: conn} do
      user = insert(:user)
      view = tab(conn, user)
      author = followed_author(user, username: "quotable")

      {:ok, _post} =
        Posts.create_post(author, %{body: "Frisch geflasht, **unter zwei Sekunden**"})

      assert_push_event(view, "tab:teaser", %{frames: [first | _] = frames})
      assert first =~ "@quotable"
      # The body arrives as one line of plain text: no Markdown, no asterisks.
      assert Enum.join(frames, " ") =~ "Frisch geflasht, unter zwei Sekunden"
      # The dot is a separate promise and is made too.
      assert_push_event(view, "tab:new_post", %{})
    end

    test "names a remote author without their server", %{conn: conn} do
      user = insert(:user)
      view = tab(conn, user)
      account = remote_account(user, "them")

      assert :ok =
               Fediverse.record_remote_post(
                 remote_note(account, "frisch von drüben"),
                 account.actor_uri
               )

      assert_push_event(view, "tab:teaser", %{frames: frames})
      line = Enum.join(frames, " ")
      assert line =~ "@them"
      refute line =~ "social.example"
      assert line =~ "frisch von drüben"

      # The fediverse nudge carries no entry, so the dot rides on the lookup
      # that found something for this reader rather than being pushed blind.
      assert_push_event(view, "tab:new_post", %{})
    end

    test "your own post never teases your own tab", %{conn: conn} do
      user = insert(:user, email_confirmed?: true)
      view = tab(conn, user)

      {:ok, _post} = Posts.create_post(user, %{body: "etwas von mir"})

      refute_push_event(view, "tab:teaser", %{})
    end
  end

  describe "what is not spent" do
    test "a tab the member is reading gets the dot and no teaser", %{conn: conn} do
      user = insert(:user)
      view = tab(conn, user, false)
      author = followed_author(user)

      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})

      assert_push_event(view, "tab:new_post", %{})
      refute_push_event(view, "tab:teaser", %{})
    end

    test "a member who switched the teaser off keeps the plain dot", %{conn: conn} do
      user = insert(:user, browser_tab_teaser?: false)
      view = tab(conn, user)
      author = followed_author(user)

      {:ok, _post} = Posts.create_post(author, %{body: "etwas Neues"})

      assert_push_event(view, "tab:new_post", %{})
      refute_push_event(view, "tab:teaser", %{})
    end

    test "a muted word is never quoted into the tab", %{conn: conn} do
      user = insert(:user)
      {:ok, _filter} = ContentFilters.create_filter(user, %{kind: :keyword, pattern: "Kessel"})
      view = tab(conn, user)
      author = followed_author(user)

      {:ok, _post} = Posts.create_post(author, %{body: "Der Kessel läuft wieder"})

      # The tab is the one place a member cannot scroll past it, so the quote
      # gives up entirely rather than being redacted.
      refute_push_event(view, "tab:teaser", %{})
      assert_push_event(view, "tab:new_post", %{})
    end
  end

  describe "more than one inside the window" do
    test "the second arrival is counted, not quoted again", %{conn: conn} do
      user = insert(:user)
      view = tab(conn, user)
      author = followed_author(user)

      {:ok, _first} = Posts.create_post(author, %{body: "der erste Beitrag"})
      assert_push_event(view, "tab:teaser", %{frames: _})

      {:ok, _second} = Posts.create_post(author, %{body: "und gleich der zweite"})

      assert_push_event(view, "tab:teaser_more", %{text: text})
      assert text =~ "1"
      # A second quote would stand for less time than it takes to read one.
      refute_push_event(view, "tab:teaser", %{})
    end
  end

  describe "the silence after a window" do
    test "an arrival inside it spends no lookup", %{conn: conn} do
      put_config(:tab_teaser_cooldown_ms, 30_000)

      user = insert(:user)
      view = tab(conn, user)
      author = followed_author(user)

      {:ok, _first} = Posts.create_post(author, %{body: "der erste Beitrag"})
      assert_push_event(view, "tab:teaser", %{frames: _})

      # Past the window this would be a fresh quote; inside the silence that
      # follows it, the socket does not go back to the database at all.
      send(view.pid, {:new_post, %{post_id: Vutuv.UUIDv7.generate(), author_id: author.id}})
      refute_push_event(view, "tab:teaser", %{})
    end

    test "a quote the reader may not see spends it too", %{conn: conn} do
      # The refusal is the branch with no rate limit of its own: it looks up,
      # finds nothing it may show, and would otherwise look up again on the very
      # next arrival — worst for the member who muted the word a busy account
      # keeps writing. Remove the `arm_quiet/2` on that branch and the second
      # post below is quoted.
      put_config(:tab_teaser_cooldown_ms, 30_000)

      user = insert(:user)
      {:ok, _filter} = ContentFilters.create_filter(user, %{kind: :keyword, pattern: "Kessel"})
      view = tab(conn, user)
      author = followed_author(user)

      {:ok, _muted} = Posts.create_post(author, %{body: "Der Kessel läuft wieder"})
      refute_push_event(view, "tab:teaser", %{})

      {:ok, _other} = Posts.create_post(author, %{body: "etwas ganz anderes"})
      refute_push_event(view, "tab:teaser", %{})
    end
  end

  # The gap that made the whole feature read as broken in production while every
  # test above stayed green (fixed 2026-08-25). `tab_hidden?` lives in the
  # socket, so a rejoin — a deploy, a laptop waking, any network blip — starts
  # it at false again, and nothing on the client volunteers the answer a second
  # time: `mounted()` runs once (the element survives the patch) and a tab that
  # was hidden throughout fires no `visibilitychange`. So every long-lived
  # background tab fell silent after its first reconnect, and stayed silent.
  #
  # It hid well because the *dot* kept working: `tab:new_post` is pushed
  # unconditionally and gated in the browser, so the tab still said that
  # something had landed and only the teaser was gone.
  describe "a socket that rejoins while the tab stays hidden" do
    test "a shell that has not heard from the hook spends nothing", %{conn: conn} do
      user = insert(:user)
      author = followed_author(user)

      # No `tab:visibility` at all — the state a reconnected tab is in until it
      # reports again, and the reason the hook must report on `reconnected()`.
      {token, _session} = Sessions.start_session(user, build_conn(), alert: false)

      {:ok, view, _html} =
        live_isolated(conn, VutuvWeb.ShellLive, session: %{"session_token" => token})

      {:ok, _post} = Posts.create_post(author, %{body: "nach dem Reconnect"})

      assert_push_event(view, "tab:new_post", %{})
      refute_push_event(view, "tab:teaser", %{})

      # …and the very same shell teases the moment the hook speaks, which is
      # what `reconnected()` restores.
      render_hook(view, "tab:visibility", %{"hidden" => true})
      {:ok, _second} = Posts.create_post(author, %{body: "und jetzt doch"})
      assert_push_event(view, "tab:teaser", %{frames: _})
    end

    test "the hook re-reports on reconnect" do
      assert Regex.match?(
               ~r/reconnected\(\)\s*\{[^}]*this\.reportVisibility\(\)/,
               tab_badge_hook()
             ),
             """
             TabBadge in #{@app_js} must re-report visibility from a \
             `reconnected()` callback. Neither `mounted()` nor \
             `visibilitychange` fires for a tab that stayed hidden across a \
             rejoin, and the server's `tab_hidden?` resets to false on every \
             one — so without it the teaser goes quiet for good on the first \
             deploy that reconnects the socket.\
             """
    end
  end

  # Just the TabBadge hook, so the assertion above cannot be satisfied by some
  # other hook's `reconnected()` further down the file.
  defp tab_badge_hook do
    case String.split(File.read!(@app_js), "\n  TabBadge: {\n", parts: 2) do
      [_before, rest] -> rest |> String.split("\n  },\n", parts: 2) |> hd()
      [_whole] -> flunk("No `TabBadge: {` hook in #{@app_js} — was it renamed?")
    end
  end
end
