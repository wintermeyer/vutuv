defmodule VutuvWeb.SettingsHubTest do
  @moduledoc """
  The information architecture of the settings area: the grouped map in
  `VutuvWeb.UI.settings_menu/1`, the hub page that renders it, and the two
  moves the restructure made (the username out of Sign-in & security into
  Profile, the blocked list into the settings shell).

  These are deliberately structural assertions — group sizes, unique keys, a
  hint on every row — because the failure mode being guarded against is not a
  broken page but a menu that silently grows back into a 25-row list with a
  "More" drawer at the end.
  """
  use VutuvWeb.ConnCase, async: true

  alias VutuvWeb.UI

  # Every row of the menu, flattened, regardless of its group.
  defp rows(user), do: Enum.flat_map(UI.settings_menu(user), fn {_group, rows} -> rows end)

  defp group(user, label) do
    {_label, rows} = Enum.find(UI.settings_menu(user), fn {name, _} -> name == label end)
    rows
  end

  describe "the settings menu" do
    setup do
      %{user: insert(:user)}
    end

    test "is grouped into named, scannable groups with no junk drawer", %{user: user} do
      menu = UI.settings_menu(user)
      names = Enum.map(menu, fn {name, _} -> name end)

      assert names == [
               "Profile",
               "Contact details",
               "Notifications & feed",
               "Privacy",
               "Account"
             ]

      # "More"/"Other" is what a menu is called when nobody could say what the
      # rows have in common; every group here names its subject.
      refute "More" in names
      refute "Other" in names

      # A group you have to scroll is a group you scan instead of read.
      for {name, rows} <- menu do
        assert length(rows) <= 8, "#{name} has #{length(rows)} rows, more than a glance holds"
        assert rows != []
      end
    end

    test "every row says what is inside it and carries search terms", %{user: user} do
      for row <- rows(user) do
        assert is_binary(row.label) and row.label != ""
        assert is_binary(row.path) and row.path != ""

        assert is_binary(row.hint) and row.hint != "",
               "#{row.label} has no hint, so the row cannot tell you what it holds"

        assert is_binary(row.terms) and row.terms != "",
               "#{row.label} has no search terms"
      end
    end

    test "keys are unique, so the sidebar can mark exactly one row active", %{user: user} do
      keys = Enum.map(rows(user), & &1.key)
      assert keys == Enum.uniq(keys)
    end

    test "exactly one row is the destructive one", %{user: user} do
      assert [%{key: :delete}] = Enum.filter(rows(user), & &1.danger)
    end

    test "the username sits under Profile, not under the account credentials", %{user: user} do
      assert %{path: "/settings/username", hint: hint} =
               Enum.find(group(user, "Profile"), &(&1.key == :username))

      # The hint shows the handle itself, so the row is recognisable at a glance.
      assert hint == "@" <> user.username

      refute Enum.any?(group(user, "Account"), &(&1.key == :username))
    end

    test "the menu has the same shape whether or not the member uses a feature", %{user: user} do
      # Rows that appear and disappear (followed tags, saved searches) make the
      # menu change under you between visits, and a hidden row is unfindable by
      # definition. They are always listed now; their pages explain themselves
      # when empty.
      keys = Enum.map(rows(user), & &1.key)
      assert :followed_tags in keys
      assert :saved_searches in keys

      insert(:tag) |> then(&Vutuv.Tags.follow_tag(user, &1))

      assert Enum.map(rows(user), & &1.key) == keys
    end

    test "the two language rows are told apart by name", %{user: user} do
      labels = Enum.map(rows(user), & &1.label)

      # "Languages" (spoken, on the CV) next to "Language & display" (the
      # interface) read as the same thing on a quick scan.
      assert "Language skills" in labels
      assert "Language & display" in labels
      refute "Languages" in labels
    end

    test "no row repeats the name of its own group", %{user: user} do
      for {name, rows} <- UI.settings_menu(user), row <- rows do
        refute row.label == name, "#{name} > #{row.label} reads as a loop"
      end
    end
  end

  describe "the hub page" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "renders every menu row as a searchable row", %{conn: conn, user: user} do
      html = conn |> get(~p"/settings") |> html_response(200)

      for row <- rows(user) do
        assert html =~ ~s(href="#{row.path}"), "the hub does not link #{row.label}"
      end
    end

    test "each row carries its label, hint and synonyms as one search string", %{
      conn: conn,
      user: user
    } do
      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ ~s(data-settings-filter)

      # Typing a word the label does not use must still find the row: the
      # search string folds in the hint and a list of synonyms.
      username = Enum.find(rows(user), &(&1.key == :username))
      needle = UI.settings_search_text(username)

      assert needle == String.downcase(needle)
      assert needle =~ "username"
      assert needle =~ "handle"
      assert html =~ ~s(data-search="#{needle}")
    end

    # A setting that is one click away but that the filter box cannot find is
    # unfindable in practice — the hub is 25 rows deep. The date shape and the
    # time zone (issue #1502) landed on a page whose row was written before
    # they existed, so its synonyms named neither.
    test "the date and time settings are findable by the words a member types", %{
      conn: conn,
      user: user
    } do
      needle =
        rows(user)
        |> Enum.find(&(&1.key == :preferences))
        |> UI.settings_search_text()

      for word <- ~w(zeitzone timezone datum date uhrzeit format) do
        assert needle =~ word, ~s(the settings filter cannot find "#{word}")
      end

      # Asserted on a fragment rather than the whole haystack: this row's label
      # carries an "&", which the attribute renders escaped.
      assert conn |> get(~p"/settings") |> html_response(200) =~ "zeitzone timezone"
    end

    # The filter matches the *translated* haystack, so an English-only check
    # would pass while a German member still finds nothing — and the synonym
    # list is exactly the kind of string `gettext.extract --merge` carries over
    # fuzzily when it is reworded.
    test "the German synonyms carry the date and time words too", %{conn: conn} do
      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings")
        |> html_response(200)

      for word <- ~w(zeitzone datum uhrzeit datumsformat) do
        assert html =~ word, ~s(the German settings filter cannot find "#{word}")
      end
    end

    test "the desktop content pane shows the map instead of an empty state", %{conn: conn} do
      html = conn |> get(~p"/settings") |> html_response(200)

      # The pane used to hold one line pointing at the sidebar, which left ~75%
      # of a desktop screen blank.
      refute html =~ "Pick a section from the menu on the left"
      assert html =~ ~s(data-settings-map)
    end

    test "shows an entry count for the profile and contact sections", %{conn: conn, user: user} do
      insert_list(2, :work_experience, user: user)
      insert(:url, user: user)

      html = conn |> get(~p"/settings") |> html_response(200)

      assert html =~ ~s(<span data-hub-count="work">2</span>)
      assert html =~ ~s(<span data-hub-count="links">1</span>)
      assert html =~ ~s(<span data-hub-count="education">0</span>)
    end

    test "carries no destructive control, only the door to it", %{conn: conn} do
      html = conn |> get(~p"/settings") |> html_response(200)

      refute html =~ ~s(id="delete-account")
      assert html =~ ~s(href="#{~p"/settings/delete"}")
    end
  end

  describe "the username page" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "holds the profile address, the rename form and the permanent link", %{
      conn: conn,
      user: user
    } do
      html = conn |> get(~p"/settings/username") |> html_response(200)

      # The everyday address and the rename form.
      assert html =~ url(~p"/#{user}")
      # Assert the rendered action=, not a route this test knows exists.
      assert html =~ ~s(action="#{~p"/settings/username"}")
      # The permanent link moved here off the security page: it is a sharing
      # affordance, not a credential.
      assert html =~ url(~p"/system/permalinks/users/#{user.id}")
      assert html =~ ~s(id="permalink-url")
    end

    test "renaming through the form works", %{conn: conn, user: user} do
      # Two steps since issue #1086: the form remembers the handle, a PIN (or a
      # passkey / authenticator code) commits it.
      conn = post(conn, ~p"/settings/username", user: %{"username" => "neuer_name"})
      assert html_response(conn, 200) =~ "@neuer_name"

      conn =
        submit_with_csrf(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => sent_pin()}
        })

      assert redirected_to(conn) == "/neuer_name"
      assert Repo.get(Vutuv.Accounts.User, user.id).username == "neuer_name"
    end

    test "the old /settings/usernames/new URL redirects here", %{conn: conn} do
      assert conn |> get("/settings/usernames/new") |> redirected_to() == "/settings/username"
    end
  end

  describe "the sign-in & security page after the move" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "keeps the credentials and hands the username on", %{conn: conn} do
      html = conn |> get(~p"/settings/security") |> html_response(200)

      # Still the credential cluster.
      assert html =~ "Last active"
      assert html =~ "data-webauthn-register"

      # The username and the permanent link are no longer this page's business,
      # but the one place people used to find them still points the way.
      refute html =~ ~s(id="permalink-url")
      assert html =~ ~s(href="#{~p"/settings/username"}")
    end
  end

  describe "the blocked list" do
    test "renders inside the settings shell, so it is not a trip outside", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/blocks") |> html_response(200)

      assert html =~ "data-settings-shell"
      assert html =~ ~s(id="block-someone-form")
      # And the way back to the rest of the settings.
      assert html =~ ~s(href="#{~p"/settings"}")
    end
  end
end
