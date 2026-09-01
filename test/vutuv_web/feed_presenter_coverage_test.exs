defmodule VutuvWeb.FeedPresenterCoverageTest do
  @moduledoc """
  Every presenter of a feed row must show everything the row carries, for every
  shape `Vutuv.Posts.feed_sources/3` can produce — issue #1880, where two
  different halves of that sentence were false at once.

  The row shapes are what broke it. Four of the nine sources hand over a map
  with no `%Post{}` (a cached post, a boost, a member's reshare of either, and a
  reply from out there that carries no `:remote_post` key at all), and both
  machine presenters read `post.id` off it: `/api/2.0/feed` and all four
  `/feed.<ext>` siblings answered 500 to any member who follows one account out
  there. Underneath that, a feed row is a **conversation** — `collapse_threads/1`
  folds every post of one thread that reached the page into a single entry — and
  every flat presenter drew the carrier alone, so the post an answer answered was
  on no page of the feed at all while the HTML page beside it drew the whole
  exchange.

  So this asks the one question both bugs failed: `Vutuv.Posts.feed_subjects/1`
  says what a row is about, and each presenter's output has to name all of it.
  The oracle is deliberately the context function rather than a list written
  here — a tenth source, or a fourth row shape, joins the fixture below and is
  then checked everywhere at once instead of in whichever presenter somebody
  remembered.

  `async: false` because the last case holds the global
  `:verify_organization_domains` flag down for the module's lifetime, and the
  DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers, only: [remote_account: 1, cached_post: 2]

  alias Vutuv.ApiAuth
  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Repo

  # One row of every shape a member's feed can hold, each carrying a sentence
  # nothing else on the page says, so "is this row's content present" is a
  # substring question rather than a structural one.
  defp seed_every_shape(me) do
    author = insert_activated_user(first_name: "Anna", last_name: "Autor")
    sharer = insert_activated_user(first_name: "Sina", last_name: "Share")
    follow!(me, author)
    follow!(me, sharer)

    # A plain post by a followed member, and — the folded case — a post of that
    # member's that somebody answers, so the row is a conversation of two.
    {:ok, _plain} = Posts.create_post(author, %{body: "EIN EINZELNER BEITRAG"})
    {:ok, parent} = Posts.create_post(author, %{body: "DER BEANTWORTETE BEITRAG"})
    {:ok, _reply} = Posts.create_reply(author, parent, %{body: "DIE ANTWORT DARAUF"})

    # A member here reshares somebody's post.
    {:ok, reposted} = Posts.create_post(insert_activated_user(), %{body: "DER GETEILTE BEITRAG"})
    :ok = Posts.repost_post(sharer, reposted)

    # A post by an account the member follows on another network.
    followed = remote_account(handle: "thea", name: "Thea Remote")
    accept_follow!(me, followed)
    cached_post(followed, content_text: "EIN BEITRAG VON DRUEBEN")

    # ...one that account boosted, by somebody nobody here follows.
    stranger = remote_account(handle: "fremd", name: "Fremde Person")
    boosted = cached_post(stranger, content_text: "EIN GEBOOSTETER BEITRAG")
    boost!(followed, boosted)

    # ...one a member **here** reshared, which is how it reaches a reader who
    # follows nobody out there.
    passed_on = cached_post(stranger, content_text: "EIN WEITERGEREICHTER BEITRAG")
    Repo.insert!(%Fediverse.PostRepost{user_id: sharer.id, remote_post_id: passed_on.id})

    # ...and a **reply** from out there that a member here passed on — the shape
    # that carries no `:remote_post` key at all.
    {:ok, mine} = Posts.create_post(me, %{body: "MEINE FRAGE"})

    note =
      insert(:note,
        post: mine,
        actor_uri: stranger.actor_uri,
        handle: stranger.handle,
        content_text: "EINE WEITERGEREICHTE ANTWORT"
      )

    Repo.insert!(%Fediverse.NoteRepost{user_id: sharer.id, note_id: note.id})
  end

  defp accept_follow!(user, account) do
    Repo.insert!(%Fediverse.Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp boost!(booster, %Fediverse.RemotePost{} = post) do
    Repo.insert!(%Fediverse.PostBoost{
      remote_account_id: booster.id,
      remote_post_id: post.id,
      activity_id: "https://social.example/announce/#{post.id}",
      announced_at: DateTime.utc_now(:second)
    })
  end

  # What every presenter owes the reader, straight from the context: the text of
  # each record the rows carry. `Posts.text/1` answers for all three post kinds,
  # so a fourth arrives here already handled.
  defp texts_owed(viewer) do
    viewer
    |> Posts.feed_page(limit: 50)
    |> Map.fetch!(:entries)
    |> Enum.flat_map(&Posts.feed_subjects/1)
    |> Enum.map(&Posts.text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp missing(body, texts), do: Enum.reject(texts, &String.contains?(body, &1))

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()

    # The organization helpers below flip this global flag and the DNS stub
    # beside it; the module is `async: false` for that too.
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    {conn, me} = create_and_login_user(conn)
    seed_every_shape(me)

    texts = texts_owed(me)

    # The fixture is only worth what it covers: nine sentences means every shape
    # above really reached the page. A silently empty feed would make every
    # assertion below vacuously true.
    assert length(texts) == 9, "the fixture stopped covering every row shape: #{inspect(texts)}"

    {:ok, conn: conn, me: me, texts: texts}
  end

  test "the agent formats name every record their rows carry", %{conn: conn, texts: texts} do
    for ext <- ~w(md txt json xml) do
      body = recycle(conn) |> get("/feed.#{ext}") |> response(200)
      assert missing(body, texts) == [], "/feed.#{ext} lost: #{inspect(missing(body, texts))}"
    end
  end

  test "the API names every record its rows carry", %{me: me, texts: texts} do
    {:ok, token, _} = ApiAuth.create_pat(me, %{"name" => "t", "scopes" => ["posts:read"]})

    body = get(authed(build_conn(), token), "/api/2.0/feed?limit=50").resp_body
    assert missing(body, texts) == [], "/api/2.0/feed lost: #{inspect(missing(body, texts))}"
  end

  # The reference the three above are measured against: this page was always
  # right, which is what made the others' silence so hard to see — the same
  # conversation read whole here and came back one post short everywhere else.
  test "the HTML feed names every record its rows carry", %{conn: conn, texts: texts} do
    html = conn |> get(~p"/feed") |> html_response(200)
    assert missing(html, texts) == [], "/feed lost: #{inspect(missing(html, texts))}"
  end

  # A page's feed folds a conversation the same way and drew the carrier alone,
  # so a post a followed member had answered left it for good — the cursor had
  # already walked past its own row, so no later page brought it back.
  test "a page's feed shows the post an answer answers" do
    {conn, owner} =
      build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

    page = Vutuv.OrganizationsHelpers.active_organization_for(owner)
    {:ok, _} = Vutuv.Organizations.add_role(page, owner, "publisher", owner)

    author = insert_activated_user(first_name: "Anna", last_name: "Autor")
    {:ok, _} = Vutuv.Social.follow_as_organization(page, author)

    {:ok, parent} = Posts.create_post(author, %{body: "DER BEANTWORTETE BEITRAG"})
    {:ok, _reply} = Posts.create_reply(author, parent, %{body: "DIE ANTWORT DARAUF"})

    html = conn |> get(~p"/organizations/#{page.slug}/feed") |> html_response(200)

    assert html =~ "DIE ANTWORT DARAUF"
    assert html =~ "DER BEANTWORTETE BEITRAG"
  end
end
