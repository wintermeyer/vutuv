defmodule VutuvWeb.UserProfileLiveTest do
  @moduledoc """
  The profile page is a LiveView (`VutuvWeb.UserProfileLive`, embedded by
  `UserController.show` via `live_render`). These cover the reload-free viewer
  actions and the cross-page live updates — that the follower/following counts
  and tag endorsements reflect a change made from anywhere, over PubSub. The
  disconnected render and the agent-format siblings are covered by the
  controller test (`user_controller_test.exs`); here every assertion drives the
  connected socket.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts
  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.Tags

  describe "follow / unfollow without a reload" do
    test "following flips the header pill and reveals the follower count", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The pill starts on the brand "Follow" call to action and there is no
      # follower count yet (a bare "0 followers" says nothing, so it is hidden).
      assert has_element?(view, ~s(button[phx-click="follow"][phx-value-followee="#{owner.id}"]))
      refute has_element?(view, ~s([href="/#{owner.username}/followers"]))

      view
      |> element(~s(button[phx-click="follow"][phx-value-followee="#{owner.id}"]))
      |> render_click()

      # The pill is now the green "Following" (an unfollow toggle) and the
      # follower count link appeared — all without a page reload.
      assert has_element?(view, ~s(button[phx-click="unfollow"]))
      refute has_element?(view, ~s(button[phx-click="follow"][phx-value-followee="#{owner.id}"]))
      assert has_element?(view, ~s([href="/#{owner.username}/followers"]))
    end

    test "unfollowing flips the pill back and hides the follower count", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:follow, follower: viewer, followee: owner)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      assert has_element?(view, ~s(button[phx-click="unfollow"]))
      assert has_element?(view, ~s([href="/#{owner.username}/followers"]))

      view |> element(~s(button[phx-click="unfollow"])) |> render_click()

      assert has_element?(view, ~s(button[phx-click="follow"][phx-value-followee="#{owner.id}"]))
      refute has_element?(view, ~s([href="/#{owner.username}/followers"]))
    end
  end

  describe "tag endorsement without a reload" do
    test "endorsing flips the pill toggle and bumps the count", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      user_tag = insert(:user_tag, user: owner, tag: tag)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      endorse = ~s(button[phx-click="endorse"][phx-value-id="#{user_tag.id}"])
      assert has_element?(view, endorse)

      view |> element(endorse) |> render_click()

      # The same pill is now the "unendorse" toggle, filled in (data-endorsed).
      assert has_element?(
               view,
               ~s(button[phx-click="unendorse"][phx-value-id="#{user_tag.id}"][data-endorsed="true"])
             )

      # Undo returns it to the endorse state.
      view
      |> element(~s(button[phx-click="unendorse"][phx-value-id="#{user_tag.id}"]))
      |> render_click()

      assert has_element?(view, endorse)
    end
  end

  describe "tags card ordering and cap" do
    test "an honor tag leads the section, ahead of an endorsed self-assigned tag", %{conn: conn} do
      owner = insert_activated_user()

      # A self-assigned tag with a visible endorsement.
      popular = insert(:user_tag, user: owner, tag: insert(:tag, name: "Elixir", slug: "elixir"))
      insert(:user_tag_endorsement, user_tag: popular, user: insert_activated_user())

      # An honor tag (never endorsable, count 0) must still render first.
      insert(:user_tag,
        user: owner,
        tag: insert(:tag, name: "Vutuv Developer", slug: "vutuv_developer", honor?: true)
      )

      {:ok, _view, html} = live(conn, ~p"/#{owner}")

      {honor_at, _} = :binary.match(html, "/#{owner.username}/tags/vutuv_developer")
      {popular_at, _} = :binary.match(html, "/#{owner.username}/tags/elixir")
      assert honor_at < popular_at
    end

    test "renders up to 30 tags, then hands off to the View-all footer", %{conn: conn} do
      owner = insert_activated_user()

      # 31 tags (all zero-endorsement, so slug-alphabetical): tag01 .. tag31.
      for i <- 1..31 do
        slug = "tag" <> String.pad_leading(Integer.to_string(i), 2, "0")
        insert(:user_tag, user: owner, tag: insert(:tag, name: slug, slug: slug))
      end

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The 30th tag renders (the old cap was 10, so this proves the higher cap),
      chip = fn slug -> ~s(a[href="/#{owner.username}/tags/#{slug}"]) end
      assert has_element?(view, chip.("tag30"))
      # but the 31st is cut, and the "View all (31)" footer links to the full list.
      refute has_element?(view, chip.("tag31"))
      assert has_element?(view, ~s(a[href="/#{owner.username}/tags"]))
    end
  end

  describe "live updates from another page" do
    test "a follow made elsewhere bumps this profile's follower count live", %{conn: conn} do
      owner = insert_activated_user()

      # An anonymous visitor is watching the profile.
      {:ok, view, _html} = live(conn, ~p"/#{owner}")
      refute has_element?(view, ~s([href="/#{owner.username}/followers"]))

      # Someone follows the owner from a totally different page; the open
      # profile reflects it over PubSub, no reload.
      follower = insert(:user, email_confirmed?: true)
      {:ok, _} = Social.follow(follower, owner.id)

      assert has_element?(view, ~s([href="/#{owner.username}/followers"]))
    end

    test "an endorsement made elsewhere bumps this profile's tag count live", %{conn: conn} do
      owner = insert_activated_user()
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      user_tag = insert(:user_tag, user: owner, tag: tag)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # No endorsements yet, so the read-only pill is hidden (count 0).
      refute render(view) =~ "rounded-full bg-brand-100 px-1"

      # A logged-in member endorses the tag from elsewhere.
      endorser = insert_activated_user()
      {:ok, _} = Tags.create_endorsement(%{user_tag_id: user_tag.id, user_id: endorser.id})

      # The watching profile now shows the count-1 pill, live.
      assert render(view) =~ "rounded-full bg-brand-100 px-1"
    end
  end

  describe "the ⋯ menu actions without a reload" do
    test "mute / unmute flips the menu label", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:follow, follower: viewer, followee: owner)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      assert view |> element(~s(button[phx-click="toggle_mute"])) |> render_click() =~ "Unmute"
      assert view |> element(~s(button[phx-click="toggle_mute"])) |> render_click() =~ "Mute"
    end

    test "bookmark / like toggle the menu item between save and remove", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      assert has_element?(view, ~s(button[phx-click="bookmark_user"]))
      view |> element(~s(button[phx-click="bookmark_user"])) |> render_click()
      assert has_element?(view, ~s(button[phx-click="unbookmark_user"]))

      assert has_element?(view, ~s(button[phx-click="like_user"]))
      view |> element(~s(button[phx-click="like_user"])) |> render_click()
      assert has_element?(view, ~s(button[phx-click="unlike_user"]))
    end

    test "blocking swaps the controls to Unblock, and unblocking restores them", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{owner}")
      assert has_element?(view, ~s(button[phx-click="block_user"]))

      # render_click bypasses the data-confirm dialog (no JS in the test).
      view |> element(~s(button[phx-click="block_user"])) |> render_click()
      assert has_element?(view, "#unblock-user")
      refute has_element?(view, ~s(button[phx-click="block_user"]))

      view |> element("#unblock-user") |> render_click()
      refute has_element?(view, "#unblock-user")
      # The follow pill is back once the block is gone.
      assert has_element?(view, ~s(button[phx-click="follow"][phx-value-followee="#{owner.id}"]))
    end
  end

  describe "list (user_row) follow without a reload" do
    test "following a member in the followers list flips that row's button", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      # A third member follows the owner, so they appear in the followers preview.
      other = insert_activated_user()
      insert(:follow, follower: other, followee: owner)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      row_follow = ~s(button[phx-click="follow"][phx-value-followee="#{other.id}"])
      assert has_element?(view, row_follow)

      view |> element(row_follow) |> render_click()
      # The row's button flipped to "Following" (an unfollow toggle), no reload.
      refute has_element?(view, row_follow)
    end

    test "the following-state row pill is a toggle carrying both labels", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      # `other` follows the owner (so they show in the followers preview) and the
      # viewer already follows `other` (so the row sits in its "following" state).
      other = insert_activated_user()
      insert(:follow, follower: other, followee: owner)
      insert(:follow, follower: viewer, followee: other)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The pill is the unfollow toggle, and it carries both the resting
      # "Following" label and the hover-revealed "Unfollow" label (the CSS swap),
      # so the control states what clicking it does.
      pill =
        view
        |> element(~s(#profile-followers button[phx-click="unfollow"][phx-value-id]))
        |> render()

      assert pill =~ "Following"
      assert pill =~ "Unfollow"
    end
  end

  describe "'Who to follow' rail suggestions" do
    test "excludes members the viewer already follows", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      owner = insert_activated_user()

      # The owner's leading tag drives the topical suggestions: everyone endorsed
      # for it is a candidate.
      tag = insert(:tag)
      insert(:user_tag, user: owner, tag: tag)

      already_followed = insert_activated_user()
      not_followed = insert_activated_user()
      insert(:user_tag, user: already_followed, tag: tag)
      insert(:user_tag, user: not_followed, tag: tag)
      # The viewer already follows one of the two candidates.
      insert(:follow, follower: viewer, followee: already_followed)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      rail = "#profile-who-to-follow"
      # The not-yet-followed candidate is suggested; the already-followed one is
      # not (suggesting someone you already follow makes no sense).
      assert has_element?(view, ~s(#{rail} a[href="/#{not_followed.username}"]))
      refute has_element?(view, ~s(#{rail} a[href="/#{already_followed.username}"]))
      # And the viewer is never suggested to follow themselves.
      refute has_element?(view, ~s(#{rail} a[href="/#{viewer.username}"]))
    end
  end

  describe "no 'View as' switcher (removed)" do
    test "the owner always sees their own full view; there is no switcher to preview",
         %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:email, user: owner, value: "secret@example.com", public?: false)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The whole toggle is gone: no switcher, no preview banner, no phx-click
      # tier buttons. To see the public view an owner logs out.
      refute has_element?(view, "#view-as-switcher")
      refute has_element?(view, "#view-as-banner")
      refute has_element?(view, ~s([phx-click="view_as"]))

      # Their own view still carries the private email and the owner chrome.
      assert render(view) =~ "secret@example.com"
    end
  end

  describe "contact card fades private email addresses" do
    test "the owner reads every address, but private ones are faded and lock-tagged",
         %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:email, user: owner, value: "shown@example.com", public?: true)
      insert(:email, user: owner, value: "hidden@example.com", public?: false)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The owner sees both addresses.
      assert render(view) =~ "shown@example.com"
      assert render(view) =~ "hidden@example.com"

      # The private row is tagged private, faded (opacity), and carries the
      # "only visible to you" lock label; the public row is neither.
      assert has_element?(
               view,
               ~s(#profile-contact a[data-email-visibility="private"][href="mailto:hidden@example.com"])
             )

      private_row =
        element(
          view,
          ~s(#profile-contact a[data-email-visibility="private"][href="mailto:hidden@example.com"])
        )

      private_html = render(private_row)
      assert private_html =~ "opacity-55"
      assert private_html =~ "Only visible to you"

      public_html =
        render(
          element(
            view,
            ~s(#profile-contact a[data-email-visibility="public"][href="mailto:shown@example.com"])
          )
        )

      refute public_html =~ "opacity-55"
      refute public_html =~ "Only visible to you"
    end

    test "a visitor never sees the private address or its marker", %{conn: conn} do
      {_conn, owner} = create_and_login_user(conn)
      insert(:email, user: owner, value: "shown@example.com", public?: true)
      insert(:email, user: owner, value: "hidden@example.com", public?: false)

      # A logged-out visitor gets the public-only email list.
      {:ok, view, _html} = live(build_conn(), ~p"/#{owner}")

      html = render(view)
      assert html =~ "shown@example.com"
      refute html =~ "hidden@example.com"
      refute has_element?(view, ~s(#profile-contact a[data-email-visibility="private"]))
    end
  end

  describe "the owner's 'Write a post' composer trigger" do
    test "links to the feed with the composer pre-opened", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The same avatar-card trigger as the feed's (shared <.composer_trigger>,
      # not the dashed onboarding tile). It must land on /feed#compose, not
      # bare /feed — the #compose hash is what reveals and focuses the composer
      # on arrival (the same path the "n" keyboard shortcut uses), so clicking
      # it opens the new-post form straight away instead of dropping the owner
      # on a closed composer.
      trigger = element(view, "#profile-posts [data-composer-trigger]")
      assert render(trigger) =~ ~s(href="/feed#compose")
      refute has_element?(view, "#profile-posts [data-empty-add]")

      # Flat inside the post list, the trigger follows the rows' grammar: the
      # same `sm` avatar the post headers use (h-9), not the feed card's `md` —
      # a bigger avatar towers over the list and shifts the pill off the post
      # text column.
      assert render(trigger) =~ "h-9 w-9"
      refute render(trigger) =~ "h-12 w-12"
    end
  end

  describe "onboarding checklist 'Add a tag' step (issue #845)" do
    test "links to the /settings/tags/new form, not the retired /:slug/tags/new", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)

      # Strip the three registration tags so the step is incomplete: the
      # checklist only renders a *link* for a not-done step. The account is
      # freshly registered, so it is still inside the onboarding window and the
      # checklist shows.
      Repo.delete_all(from(ut in Tags.UserTag, where: ut.user_id == ^owner.id))

      {:ok, view, _html} = live(conn, ~p"/#{owner}")
      html = render(view)

      # /:slug/tags/new has no new-form route: it matches the tag show action
      # (id="new") and 404s. The add-tag form lives under /settings.
      assert html =~ "Add a tag"
      assert html =~ ~s(href="/settings/tags/new")
      refute html =~ ~s(href="/#{owner.username}/tags/new")
    end
  end

  describe "posts section author links" do
    test "a post author's avatar and name link to their profile", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      {:ok, _post} = Posts.create_post(owner, %{body: "just setting up my vutuv"})

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The threaded posts list names the author and shows their avatar; both
      # are links to that member's profile so a reader can jump straight there.
      # (Two links to the same profile: the avatar — aria-hidden so the named
      # link is the one in the tab order — and the name itself.)
      assert view
             |> element(~s(#profile-posts a[href="/#{owner.username}"][aria-hidden="true"]))
             |> has_element?()

      assert view
             |> element(
               ~s(#profile-posts a[href="/#{owner.username}"]),
               VutuvWeb.UserHelpers.full_name(owner)
             )
             |> has_element?()
    end

    test "a long post expands in place on the profile (whole body, no link-out)", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      # ~1500 chars, past the old ~1000-char server cut. The profile shares the
      # feed's post card, so a long post here expands in place too — the whole
      # body is shipped (CSS clamps it) and "Read more" is the in-place toggle
      # button, never a link that jumps to the post page.
      tail = "distinctivetailmarker"
      body = (String.duplicate("lorem ", 250) |> String.trim()) <> " " <> tail
      {:ok, post} = Posts.create_post(owner, %{body: body})

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      # The whole body is in the DOM — the source is no longer truncated.
      assert html =~ tail
      assert has_element?(view, "#profile-posts [data-clamp-body].post-clamp")

      # In-place expand button, and no link-out to the permalink.
      assert has_element?(
               view,
               ~s(#profile-posts button[data-read-more][data-post-expand][aria-expanded="false"]),
               "Read more"
             )

      refute has_element?(view, ~s(#profile-posts a[data-read-more]))
      refute has_element?(view, ~s(#profile-posts a[href="#{Posts.path(post)}"][data-read-more]))
    end

    test "a reply shows the real parent post as context, linking to it", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      other = insert_activated_user()
      {:ok, parent} = Posts.create_post(other, %{body: "the original question"})
      {:ok, _reply} = Posts.create_reply(owner, parent, %{body: "my answer to it"})

      {:ok, view, html} = live(conn, ~p"/#{owner}")

      # The reply renders with the post it answers shown above it as context:
      # the parent's body, a link to the parent post, and the parent author's
      # profile link (avatar + name in the context row).
      assert html =~ "the original question"
      assert has_element?(view, ~s(#profile-posts a[href="#{Posts.path(parent)}"]))
      assert has_element?(view, ~s(#profile-posts a[href="/#{other.username}"]))

      # The card's own "Replying to" banner is suppressed — the inline parent
      # replaces it, so the relationship is shown once, not twice.
      refute has_element?(view, "[data-reply-banner]")
    end
  end

  describe "midnight day-change refresh" do
    test "a post from yesterday renders the 'Gestern'/'Yesterday' stamp", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      {:ok, post} = Posts.create_post(owner, %{body: "words from the prior day"})
      yesterday = NaiveDateTime.new!(Date.add(Vutuv.BerlinTime.today(), -1), ~T[12:00:00])
      post |> Ecto.Changeset.change(inserted_at: yesterday) |> Vutuv.Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/#{owner}")

      assert html =~ "words from the prior day"
      assert html =~ ~r/Gestern|Yesterday/
    end

    test "a :day_changed tick re-fetches the shown posts without a crash", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      {:ok, _post} = Posts.create_post(owner, %{body: "still here"})

      {:ok, view, _html} = live(conn, ~p"/#{owner}")
      assert render(view) =~ "still here"

      # The DayClock fires this at Berlin midnight; the profile re-fetches its
      # posts so the stamps re-render, and the post is still shown afterwards.
      send(view.pid, :day_changed)
      _ = :sys.get_state(view.pid)
      assert render(view) =~ "still here"
    end
  end

  describe "live post deletion" do
    test "a post deleted elsewhere drops from the open profile", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      {:ok, post} = Posts.create_post(owner, %{body: "soon deleted"})

      {:ok, view, html} = live(conn, ~p"/#{owner}")
      assert html =~ "soon deleted"

      # The deletion broadcasts {:post_deleted} on the owner's topic, which the
      # profile subscribes to — so the card drops without a reload (the action
      # bar is now an in-process component that no longer subscribes per post).
      {:ok, _} = Posts.delete_post(post)
      _ = :sys.get_state(view.pid)

      refute render(view) =~ "soon deleted"
    end
  end

  describe "languages card" do
    test "renders each language as a wrapping pill with its level, no Preferred marker",
         %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:language, user: owner, language_code: "en", proficiency: "native")
      insert(:language, user: owner, language_code: "fr", proficiency: "a2")

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # The card lays its entries out as pills in a single wrapping flex row,
      # not a stack of full-width rows.
      assert has_element?(view, "#profile-languages [data-language-pill]", "English")
      assert has_element?(view, "#profile-languages [data-language-pill]", "French")

      # Each pill still carries the compact proficiency badge (Native / A2)...
      html = render(view)
      assert html =~ "Native"
      assert html =~ "A2"

      # ...but the profile card drops the quieter "Preferred" contact-language
      # marker; that detail lives on the dedicated /:slug/languages page.
      refute has_element?(view, "#profile-languages", "Preferred")
    end
  end

  describe "profile-completion checklist" do
    # The owner's onboarding nudge (first hour after sign-up) carries a × to
    # close it for good and a link into the LinkedIn importer. The window and
    # visibility rules are covered by the disconnected controller test; here we
    # drive the connected socket's × click and the persisted effect.

    test "the × closes the checklist and persists the dismissal", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(view, "#profile-completion")
      assert has_element?(view, "#dismiss-completion")

      view |> element("#dismiss-completion") |> render_click()

      # Gone from the page immediately...
      refute has_element?(view, "#profile-completion")
      # ...and persisted, so a reload never brings it back.
      assert Accounts.get_user(user.id).onboarding_dismissed?
    end

    test "the checklist links into the LinkedIn importer", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/#{user}")

      assert has_element?(
               view,
               ~s(#profile-completion a[href="#{~p"/settings/import/linkedin"}"])
             )
    end
  end
end
