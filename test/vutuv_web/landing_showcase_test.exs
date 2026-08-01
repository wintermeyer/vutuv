defmodule VutuvWeb.LandingShowcaseTest do
  @moduledoc """
  The examples block under the logged-out landing page's sign-up form: static
  screenshots of a profile, the feature list, and a few real posts.

  What a profile looks like is answered by pictures that name nobody, so the
  interesting rules all sit on the posts: which member's post may stand on the
  front page, how recent it has to be, and that no single member can fill the
  block on their own.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Landing
  alias Vutuv.Posts

  # The snapshot cache is off in tests (:refresh_landing_showcase), so every
  # read falls through to the live query — see Vutuv.Landing.Showcase.

  defp liked_post(author, likes, attrs \\ []) do
    post = insert(:post, Keyword.merge([user: author], attrs))

    for _ <- 1..likes do
      :ok = Posts.like_post(insert(:activated_user), post)
    end

    post
  end

  # A member the posts block will consider: confirmed, and neither reach opt-out
  # set. `insert(:activated_user)` already flips email_confirmed?; noindex? /
  # noai? default to false.
  defp poster(attrs \\ []), do: insert(:activated_user, attrs)

  defp age(post, days) do
    stamp = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -days, :day)

    post |> Ecto.Changeset.change(inserted_at: stamp) |> Vutuv.Repo.update!()
  end

  describe "showcase_posts/0" do
    test "shows a post that cleared the like bar" do
      post = liked_post(poster(), 2)

      assert Enum.map(Landing.showcase_posts(), & &1.id) == [post.id]
    end

    test "leaves out a post below the like bar" do
      liked_post(poster(), 1)

      assert Landing.showcase_posts() == []
    end

    test "most liked first" do
      quiet = liked_post(poster(), 2)
      loud = liked_post(poster(), 5)

      assert Enum.map(Landing.showcase_posts(), & &1.id) == [loud.id, quiet.id]
    end

    # The mix rule. Everybody's best post is taken before anybody's second, so a
    # prolific member cannot open the wall with three of their own.
    test "takes everybody's best post before anybody's second" do
      prolific = poster()
      best = liked_post(prolific, 9)
      second = liked_post(prolific, 8)
      quiet = liked_post(poster(), 2)

      assert Enum.map(Landing.showcase_posts(), & &1.id) == [best.id, quiet.id, second.id]
    end

    # The other half of that rule, and the reason it is round-robin rather than
    # a hard one-per-member cap: on the real data a week of qualifying posts had
    # three authors, and a cap of one would have left five of eight cards empty.
    test "keeps filling from the same members when there are not enough of them" do
      a = poster()
      b = poster()
      c = poster()
      for author <- [a, b, c], likes <- 2..6, do: liked_post(author, likes)

      posts = Landing.showcase_posts()

      assert length(posts) == Landing.post_limit()
      counts = posts |> Enum.map(& &1.user_id) |> Enum.frequencies() |> Map.values()
      assert Enum.max(counts) - Enum.min(counts) <= 1
    end

    # The ceiling, and why the wall may come up short: an uncapped round-robin
    # handed one member 6 of 8 cards on the real data, which is the megaphone
    # this block exists to avoid. A short wall of different faces beats a full
    # wall of one face.
    test "never lets one member hold more than their share, even if the wall stays short" do
      hog = poster()
      for likes <- 2..12, do: liked_post(hog, likes)
      liked_post(poster(), 2)

      posts = Landing.showcase_posts()
      counts = posts |> Enum.map(& &1.user_id) |> Enum.frequencies()

      assert counts[hog.id] == Landing.max_per_author()
      assert length(posts) < Landing.post_limit()
    end

    test "one member alone cannot fill the wall" do
      hog = poster()
      for likes <- 2..12, do: liked_post(hog, likes)

      assert length(Landing.showcase_posts()) == Landing.max_per_author()
    end

    test "reaches back seven days" do
      recent = liked_post(poster(), 2) |> age(6)

      assert Enum.map(Landing.showcase_posts(), & &1.id) == [recent.id]
    end

    # A quiet week would prove the opposite of what this block claims, so it
    # widens rather than show a stub row.
    test "falls back to four weeks when the week is too quiet for a full row" do
      old = liked_post(poster(), 5) |> age(20)

      assert Enum.map(Landing.showcase_posts(), & &1.id) == [old.id]
      assert Landing.window_days() == Landing.fallback_window_days()
    end

    test "keeps the week when it filled the row on its own" do
      for _ <- 1..(div(Landing.min_cards(), 2) + 1), do: liked_post(poster(), 2)
      old = liked_post(poster(), 9) |> age(20)

      ids = Landing.showcase_posts() |> Enum.map(& &1.id)

      assert Landing.window_days() == Landing.preferred_window_days()
      refute old.id in ids
    end

    # Widening an empty installation finds the same nothing, and then the honest
    # heading is the week, not four weeks.
    test "keeps the week when widening would not help either" do
      assert Landing.showcase_posts() == []
      assert Landing.window_days() == Landing.preferred_window_days()
    end

    test "leaves out anything older than the wider window too" do
      liked_post(poster(), 9) |> age(40)

      assert Landing.showcase_posts() == []
    end

    # A member who told us search engines and AI may not have their profile has
    # said clearly enough that they are not looking for reach.
    test "respects the author's noindex opt-out" do
      liked_post(poster(noindex?: true), 5)

      assert Landing.showcase_posts() == []
    end

    test "respects the author's noai opt-out" do
      liked_post(poster(noai?: true), 5)

      assert Landing.showcase_posts() == []
    end

    test "leaves out posts of members who never confirmed their address" do
      liked_post(insert(:user, email_confirmed?: false), 5)

      assert Landing.showcase_posts() == []
    end

    test "leaves out replies (an answer to a stranger says nothing about vutuv)" do
      author = poster()
      reply = liked_post(author, 2)
      insert(:post_reply, post: reply, parent_post: insert(:post), parent_author: author)

      assert Landing.showcase_posts() == []
    end

    # A post is a reply through either sidecar, and only checking the local one
    # put a "Replying to @somebody@social.cologne" card on the landing page.
    test "leaves out replies to a post from another network" do
      reply = liked_post(poster(), 2)

      Vutuv.Repo.insert!(%Vutuv.Posts.PostRemoteReply{
        post_id: reply.id,
        in_reply_to_uri: "https://social.example/users/someone/statuses/1",
        actor_uri: "https://social.example/users/someone",
        inbox_uri: "https://social.example/users/someone/inbox",
        handle: "@someone@social.example"
      })

      assert Landing.showcase_posts() == []
    end

    test "shows no more than the block holds" do
      for _ <- 1..(Landing.post_limit() + 2), do: liked_post(poster(), 2)

      assert length(Landing.showcase_posts()) == Landing.post_limit()
    end

    # The pinboard runs up to three columns, so it needs enough cards to fill
    # them; a handful of leftovers reads as an empty site.
    test "asks for enough posts to fill a three-column wall" do
      assert Landing.post_limit() >= 6
    end

    test "preloads what the post card renders, so the page runs no N+1" do
      liked_post(poster(), 2)

      assert [post] = Landing.showcase_posts()
      assert %Vutuv.Accounts.User{} = post.user
      refute match?(%Ecto.Association.NotLoaded{}, post.images)
    end
  end

  describe "the landing page" do
    # Static pictures, not live rows: nobody has to agree to being on the front
    # page, and there is no member whose rename or departure could break it.
    test "shows the profile screenshots", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "data-profile-shots"
      assert html =~ "/images/landing-profile-overview.avif"
      assert html =~ "/images/landing-profile-cv.avif"
      assert html =~ "/images/landing-profile-links.avif"
    end

    # The fan is a marketing gesture and a phone has no room for it: three
    # tilted cards at 390px would be three unreadable slivers. Every tilt,
    # overlap and stacking class therefore has to be md:-scoped.
    test "the fanned deck stays a plain stack below md", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      decks =
        Regex.scan(~r/<div\s+data-(?:profile|communication)-shots\s+class="([^"]+)"/, html,
          capture: :all_but_first
        )

      assert length(decks) == 2
      assert Enum.all?(decks, fn [d] -> not (d =~ ~r/(^|\s)(flex-row|justify-center)/) end)

      figures =
        html
        |> String.split("<figure")
        |> Enum.filter(&String.contains?(&1, "/images/landing-"))

      assert length(figures) == 5

      for figure <- figures,
          [classes] = Regex.run(~r/class="([^"]+)"/, figure, capture: :all_but_first),
          klass <- String.split(classes),
          klass =~ ~r/rotate|^-?m[lrbt]-|^z-/ do
        assert String.starts_with?(klass, "md:"),
               "#{klass} tilts or overlaps the deck on a phone too"
      end
    end

    # The Fediverse is the one thing nobody arrives already understanding, so it
    # gets its own section: the feed receiving posts from other networks, and
    # the page where a member subscribes to an account out there.
    test "explains how people talk to each other, in both directions", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "data-communication-shots"
      assert html =~ "/images/landing-feed-fediverse.avif"
      assert html =~ "/images/landing-fediverse-following.avif"
    end

    # Three of the four promises are properties of the software and hold on every
    # installation; the fourth is the operator's alone.
    test "closes with the data-protection promises", %{conn: conn} do
      html =
        conn |> put_req_header("accept-language", "de-DE,de") |> get(~p"/") |> html_response(200)

      assert html =~ "Fair und transparent"
      assert html =~ "eigenen Servern in Deutschland"
      assert html =~ "Keine Cookies von Dritten"
      assert html =~ "Ihre Daten bleiben Ihnen"
      assert html =~ "Jederzeit wieder gehen"
      # Checkable, not a nicety: deletion cascades the addresses away, so the
      # door really is open again.
      assert html =~ "gerne wiederkommen"
      # The card that backs the other four: they are claims, this is the check.
      assert html =~ "Open Source"
      assert html =~ "wie vutuv genau funktioniert"
    end

    # The page's argument, in order: this is what a profile looks like, here is
    # what people are writing right now, and here is how far that reaches.
    test "the sections run profile, posts, communication, features", %{conn: conn} do
      liked_post(poster(), 2)

      html = conn |> get(~p"/") |> html_response(200)

      at = fn marker -> :binary.match(html, marker) |> elem(0) end

      assert at.("data-profile-shots") < at.("data-showcase-posts")
      assert at.("data-showcase-posts") < at.("data-communication-shots")
      assert at.("data-communication-shots") < at.("data-landing-features")
    end

    # AVIF only, by decision: 316 KB against 750 KB as WebP, and a second set of
    # files to keep pre-16.4 Safari served was judged not worth it.
    test "serves every screenshot as AVIF and carries no second format", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      avif = Regex.scan(~r|src="/images/landing-[a-z-]+\.avif"|, html) |> length()

      assert avif == 5
      refute html =~ "landing-profile-overview.webp"
      refute html =~ "<picture>"
    end

    # Five large images below the fold of the busiest page in the app. Each deck
    # has its own aspect ratio, so the size attributes are per image.
    test "every screenshot is lazy and carries its size, so nothing shifts", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # Matching whole <img> tags, not splitting on "<img": a split fragment runs
      # up to the NEXT img and so swallows the following <picture>'s AVIF source,
      # which counted one screenshot too many.
      shots =
        ~r|<img[^>]*>|
        |> Regex.scan(html)
        |> List.flatten()
        |> Enum.filter(&String.contains?(&1, "/images/landing-"))

      assert length(shots) == 5
      assert Enum.all?(shots, &String.contains?(&1, ~s(loading="lazy")))
      assert Enum.all?(shots, fn shot -> shot =~ ~r/width="\d+"/ and shot =~ ~r/height="\d+"/ end)
      # An alt of substance, not a filename: for a reader who cannot see the
      # picture these blocks are nothing but their alt text.
      assert Enum.all?(shots, fn shot -> shot =~ ~r/alt="[^"]{60,}"/ end)
    end

    test "shows a post that cleared the like bar", %{conn: conn} do
      liked_post(poster(), 2, body: "Ein Beitrag mit zwei Herzen.")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "data-showcase-posts"
      assert html =~ "Ein Beitrag mit zwei Herzen."
    end

    # The wall works as plain HTML for crawlers and JS-less readers; the button
    # is the enhancement on top.
    test "renders the wall in the disconnected mount", %{conn: conn} do
      liked_post(poster(), 2, body: "Ein Beitrag ohne JavaScript.")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Ein Beitrag ohne JavaScript."
      assert html =~ ~s(id="landing-posts")
    end

    # The installation default is whatever an admin set (15 lines on vutuv.de),
    # which on a pinboard turns one post into a column nobody reads past. The
    # ceiling has to reach the rendered body, not just the component's attrs.
    test "caps every card's body so no post can own a column", %{conn: conn} do
      liked_post(poster(), 2)

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "--post-clamp-desktop:6"
      assert html =~ "--post-clamp-mobile:6"
    end

    test "leaves the posts block out entirely when nothing cleared the bar", %{conn: conn} do
      liked_post(poster(), 1, body: "Ein Beitrag mit einem Herz.")

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "data-showcase-posts"
      refute html =~ "Ein Beitrag mit einem Herz."
    end

    # The installability rule: nothing on this page needs configuring, and a
    # brand-new installation with no posts at all still gets the screenshots and
    # the feature list rather than a hole.
    test "renders on an installation with no posts at all", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "data-profile-shots"
      assert html =~ "data-landing-features"
      refute html =~ "data-showcase-posts"
    end

    # The feature list is our own copy, so it does not depend on any member and
    # shows on every installation, including a brand-new empty one.
    test "lists the features", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "data-landing-features"
      assert html =~ "CV download"
    end

    # The landing page is rendered from two actions: `index`, and the rejected
    # sign-up, which shows the identical screen with the errors on it. Assigning
    # the examples in `index` alone 500ed every mistyped form.
    test "a rejected sign-up re-renders the page with its examples", %{conn: conn} do
      liked_post(poster(), 2, body: "Ein Beitrag neben dem Fehler.")

      html =
        conn
        |> post(~p"/new_registration", user: %{"first_name" => "No Email"})
        |> html_response(422)

      assert html =~ "data-profile-shots"
      assert html =~ "data-landing-features"
      assert html =~ "Ein Beitrag neben dem Fehler."
    end

    test "the sign-up form still comes first", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      form_at = :binary.match(html, "registration-form") |> elem(0)
      features_at = :binary.match(html, "data-landing-features") |> elem(0)

      assert form_at < features_at
    end
  end

  # The button only exists over the socket, and ConnTest never opens one — the
  # dead render is a different code path (issue-hardened elsewhere in this repo
  # as "green tests are necessary but not sufficient").

  # The counters only exist over the socket, and ConnTest never opens one — the
  # dead render is a different code path ("green tests are necessary but not
  # sufficient", CLAUDE.md).
  describe "the carousel over the socket" do
    import Phoenix.LiveViewTest

    test "shows like, repost and bookmark counts under each post", %{conn: conn} do
      post = liked_post(poster(), 3)

      {:ok, view, _html} = live_isolated(conn, VutuvWeb.LandingPostsLive)

      # The bar renders for a logged-out reader too — the counts are the point,
      # and pressing one sends them to the login page.
      assert has_element?(view, "#post-actions-a-#{post.id}-like")
      assert has_element?(view, "#post-actions-a-#{post.id}-repost")
      assert has_element?(view, "#post-actions-a-#{post.id}-bookmark")
    end

    # "Live" is the requirement, so it is asserted through the real broadcast
    # rather than by re-mounting: a count that only moves on reload is not it.
    test "a like from elsewhere moves the count with no reload", %{conn: conn} do
      post = liked_post(poster(), 2)

      {:ok, view, html} = live_isolated(conn, VutuvWeb.LandingPostsLive)
      assert like_count(html) == "2"

      :ok = Posts.like_post(insert(:activated_user), post)

      assert like_count(render(view)) == "3"
    end

    # The bars keep their engagement behind an `assign_new`, so a host that
    # merely re-assigns its own copy moves the state and nothing on the screen.
    # Asserting the RENDER rather than the assign is what catches that, and it
    # is what caught it here.
    test "both halves of the loop tick, not just the first", %{conn: conn} do
      post = liked_post(poster(), 2)

      {:ok, view, _html} = live_isolated(conn, VutuvWeb.LandingPostsLive)
      :ok = Posts.like_post(insert(:activated_user), post)

      counts =
        ~r/data-count="like">\s*([^<\s]+)\s*</
        |> Regex.scan(render(view), capture: :all_but_first)
        |> List.flatten()

      assert counts == ["3", "3"]
    end

    # The figure sits in its own span with whitespace around it, so a bare
    # `=~ ">3<"` would never match and the test would pass for the wrong reason
    # in one direction and fail in the other.
    defp like_count(html) do
      ~r/data-count="like">\s*([^<\s]+)\s*</
      |> Regex.run(html, capture: :all_but_first)
      |> hd()
    end

    # The marquee loops seamlessly only if the set is on the page twice, and that
    # duplicate has three obligations: no repeated element ids (invalid HTML, and
    # PostPreviewClamp keys on them), hidden from screen readers, and out of the
    # tab order — aria-hidden alone leaves its links focusable.
    test "the duplicated half is id-safe, hidden and not focusable", %{conn: conn} do
      liked_post(poster(), 2)

      {:ok, _view, html} = live_isolated(conn, VutuvWeb.LandingPostsLive)

      ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
      assert ids == Enum.uniq(ids)

      assert html =~ ~s(aria-hidden="true")
      assert html =~ "inert"
      # Both halves really are there: the same post twice, under distinct ids.
      assert html =~ "post-body-a-"
      assert html =~ "post-body-b-"
    end
  end

  # vutuv is a German site and ConnTest defaults to English, so the German
  # render is its own case — a fuzzy-filled or missing msgstr is invisible
  # otherwise (see the locale rule in CLAUDE.md).
  describe "German rendering" do
    test "the section headings are German", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "So sieht ein Profil auf vutuv aus"
      assert html =~ "Beiträge, Nachrichten und das Fediverse gleich dazu"
      # The word itself and a network people have heard of, both by name.
      assert html =~ "Fediverse"
      assert html =~ "Mastodon"
      # The part people need to read: it is a choice, made at sign-up and
      # reversible, not something that happens to them.
      # Not just "you choose" — the choice named as what it is, so somebody who
      # wants no Fediverse at all reads that it is on offer.
      assert html =~ "mit oder ohne Fediverse"
      assert html =~ "bei der Anmeldung"
      assert html =~ "in den Einstellungen ändern"
      assert html =~ "Was vutuv kann"
      assert html =~ "Selbst hosten"
    end

    test "the posts heading is German", %{conn: conn} do
      liked_post(poster(), 2)

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "Beiträge aus den letzten sieben Tagen, keine Screenshots"
    end

    # The heading has to follow the window the posts really came from; claiming
    # seven days over four weeks of posts is worse than a short carousel.
    test "the heading names four weeks once the window widened", %{conn: conn} do
      liked_post(poster(), 5) |> age(20)

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "Beiträge aus den letzten vier Wochen, keine Screenshots"
      refute html =~ "Beiträge aus den letzten sieben Tagen, keine Screenshots"
    end
  end
end
