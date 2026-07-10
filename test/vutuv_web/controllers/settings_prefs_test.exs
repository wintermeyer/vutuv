defmodule VutuvWeb.SettingsPrefsTest do
  # The /settings side of Vutuv.Prefs: the language & maps page shows the
  # member's EFFECTIVE preferences (their own value, else the installation
  # default) and the per-group reset links clear back to inheriting.
  #
  # async: false — some tests inject installation defaults into the
  # persistent_term cache (Vutuv.Prefs.Cache.store/1), node-global state.
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs
  alias Vutuv.Prefs.Cache

  defp with_installation_defaults(overrides) do
    Cache.store(Map.merge(Prefs.shipped_defaults(), overrides))
    on_exit(fn -> Cache.clear() end)
  end

  describe "the preferences page" do
    test "shows the installation defaults for an untouched member", %{conn: conn} do
      with_installation_defaults(%{post_lines_desktop: 12, default_map_service: "apple"})
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, ~p"/settings/preferences")
      html = html_response(conn, 200)

      assert html =~ ~s(id="user_post_lines_desktop")
      assert html =~ ~s(value="12")
      assert html =~ ~s(<option selected value="apple">)
    end

    test "shows the member's own value where one is set", %{conn: conn} do
      with_installation_defaults(%{post_lines_desktop: 12})
      {conn, user} = create_and_login_user(conn)
      {:ok, _user} = Prefs.admin_update_user(user, %{"post_lines_desktop" => "3"})

      conn = get(conn, ~p"/settings/preferences")
      assert html_response(conn, 200) =~ ~s(value="3")
    end

    test "offers the reset link only while a group holds an own value", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/preferences") |> html_response(200)
      refute html =~ ~s(id="reset-post-display")
      refute html =~ ~s(id="reset-maps")

      {:ok, _user} = Prefs.admin_update_user(user, %{"post_lines_desktop" => "3"})

      html = conn |> get(~p"/settings/preferences") |> html_response(200)
      assert html =~ ~s(id="reset-post-display")
      assert html =~ ~s(href="/settings/post_display/reset")
      refute html =~ ~s(id="reset-maps")
    end
  end

  describe "the reset links" do
    test "clear exactly their group back to inherit", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _user} =
        Prefs.admin_update_user(user, %{
          "post_lines_desktop" => "3",
          "post_hyphenate_desktop" => "true",
          "map_google?" => "false"
        })

      conn = post(conn, ~p"/settings/post_display/reset")
      assert redirected_to(conn) == ~p"/settings/preferences"

      user = Repo.get!(User, user.id)
      assert user.post_lines_desktop == nil
      assert user.post_hyphenate_desktop == nil
      # The maps group is untouched.
      assert user.map_google? == false
    end

    test "the maps reset clears the maps group", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _user} =
        Prefs.admin_update_user(user, %{
          "map_google?" => "false",
          "default_map_service" => "apple"
        })

      conn = post(conn, ~p"/settings/maps/reset")
      assert redirected_to(conn) == ~p"/settings/preferences"

      user = Repo.get!(User, user.id)
      assert user.map_google? == nil
      assert user.default_map_service == nil
    end
  end

  describe "rendering for readers" do
    test "an admin-set post default reaches an untouched member's feed markup" do
      with_installation_defaults(%{post_lines_desktop: 12})

      prefs = User.post_prefs(%User{})
      style = VutuvWeb.PostComponents.post_body_style(prefs)

      assert style =~ "--post-clamp-desktop:12"
    end
  end
end
