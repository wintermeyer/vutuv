defmodule VutuvWeb.SettingsFeedPageSizeTest do
  @moduledoc """
  /settings/feed — the second way to the feed's length, for the member who goes
  looking for it by name instead of finding the control under the timeline.

  The feed's own end of it is `VutuvWeb.FeedPageSizeTest`; what is asserted here
  is the settings side: that the hub lists the page, that the form posts to a
  route that exists (a rendered `action=` a ConnTest never exercises is how
  every Save button on two settings pages 404ed for eight releases), that
  pressing a number stores it, and that the reset puts the member back to
  inheriting the installation default.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Prefs

  @default Prefs.pref!(:feed_page_size).default

  describe "the hub" do
    test "lists the page by name", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings") |> html_response(200)

      assert body =~ ~p"/settings/feed"
      assert body =~ "Posts in your feed"
    end
  end

  describe "the page" do
    test "marks the size that applies and offers the round numbers", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/feed") |> html_response(200)

      assert body =~ ~s(data-page-size="#{@default}")
      assert body =~ ~s(data-page-size="250")

      # The one that applies is the one marked, whether it is stored or
      # inherited.
      assert body =~ ~r/data-page-size="#{@default}"[^>]*aria-pressed="true"/
    end

    # The form's own `action=` rather than a route this test knows: a hardcoded
    # path proves the route exists, not that the button uses it.
    test "the form posts where the button really points", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/feed") |> html_response(200)
      [_, action] = Regex.run(~r/<form[^>]*action="([^"]+)"[^>]*id="feed-page-size-form"/, body)

      conn = put(conn, action, %{"user" => %{"feed_page_size" => "50"}})

      assert redirected_to(conn) == ~p"/settings/feed"
      assert Accounts.get_user(user.id).feed_page_size == 50
    end

    test "a value outside the bounds is refused, not stored", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/feed_page_size", %{"user" => %{"feed_page_size" => "5000"}})

      assert html_response(conn, 422)
      assert is_nil(Accounts.get_user(user.id).feed_page_size)
    end
  end

  describe "the reset" do
    test "is offered only once the member holds a size of their own", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      refute conn |> get(~p"/settings/feed") |> html_response(200) =~ "reset-feed-page-size"

      {:ok, _user} = Accounts.update_user(user, %{"feed_page_size" => 50})

      assert conn |> get(~p"/settings/feed") |> html_response(200) =~ "reset-feed-page-size"
    end

    test "puts the member back to inheriting", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _user} = Accounts.update_user(user, %{"feed_page_size" => 50})

      conn = post(conn, ~p"/settings/feed_page_size/reset")

      assert redirected_to(conn) == ~p"/settings/feed"
      assert is_nil(Accounts.get_user(user.id).feed_page_size)
      assert Prefs.feed_page_size(Accounts.get_user(user.id)) == @default
    end

    # The two feed groups are separate on purpose: /settings/feed_languages
    # resets `:feed` wholesale, and a member putting their languages back must
    # not silently lose the length they chose here.
    test "the feed-languages reset leaves the length alone", %{conn: conn} do
      {_conn, user} = create_and_login_user(conn)
      {:ok, user} = Accounts.update_user(user, %{"feed_page_size" => 50})

      {:ok, user} = Prefs.reset_group(user, :feed)

      assert user.feed_page_size == 50
    end
  end
end
