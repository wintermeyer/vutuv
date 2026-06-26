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

  describe "owner 'View as' preview without a reload" do
    test "switching tiers previews and clears live", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:email, user: owner, value: "secret@example.com", public?: false)

      {:ok, view, _html} = live(conn, ~p"/#{owner}")

      # Own view: the switcher is present, no preview banner, private email shown.
      assert has_element?(view, "#view-as-switcher")
      refute has_element?(view, "#view-as-banner")
      assert render(view) =~ "secret@example.com"

      # Two tiers only: You / Public. The Follower and Vernetzt segments are both
      # gone (Follower looked like Public; Vernetzt stopped revealing anything
      # extra once private emails became owner-only).
      assert has_element?(view, ~s(button[phx-value-mode="public"]))
      refute has_element?(view, ~s(button[phx-value-mode="connection"]))
      refute has_element?(view, ~s(button[phx-value-mode="follower"]))

      # Preview as the public: banner appears and the private email drops, live.
      view |> element(~s(button[phx-click="view_as"][phx-value-mode="public"])) |> render_click()
      assert has_element?(view, "#view-as-banner")
      refute render(view) =~ "secret@example.com"

      # Back to "You": banner gone, private email back.
      view |> element(~s(button[phx-click="view_as"][phx-value-mode="you"])) |> render_click()
      refute has_element?(view, "#view-as-banner")
      assert render(view) =~ "secret@example.com"
    end
  end
end
