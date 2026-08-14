defmodule VutuvWeb.MessengerControllerTest do
  @moduledoc """
  End-to-end behaviour of the online-messengers section (issue #949): the
  owner's editor at /settings/messengers creates entries (a phone-based provider
  goes through the phone validator, a handle-based one through its own check),
  and the public /:slug/messengers page renders each entry as a click-to-chat
  deep link. The changeset rules themselves live in
  test/vutuv/profiles/messenger_test.exs.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Profiles.Messenger
  alias Vutuv.Repo

  @backend VutuvWeb.Gettext

  defp all_for(user), do: Repo.all(from(m in Messenger, where: m.user_id == ^user.id))

  describe "POST /settings/messengers" do
    test "saves a WhatsApp number canonicalised through the phone validator", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/messengers", %{
          "messenger" => %{"provider" => "WhatsApp", "value" => "0261-123456"}
        })

      assert redirected_to(conn) == ~p"/settings/messengers"
      assert [%Messenger{provider: "WhatsApp", value: "+49 261 123456"}] = all_for(user)
    end

    test "saves a WhatsApp username without running the phone validator", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/settings/messengers", %{
        "messenger" => %{"provider" => "WhatsApp", "value" => "@ada.wa"}
      })

      assert [%Messenger{provider: "WhatsApp", value: "ada.wa"}] = all_for(user)
    end

    test "rejects a phone-shaped WhatsApp value that is not a valid number", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/messengers", %{
          "messenger" => %{"provider" => "WhatsApp", "value" => "12"}
        })

      assert html_response(conn, 422) =~ "valid phone number"
      assert all_for(user) == []
    end

    test "saves a Signal contact link, the address that discloses nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/messengers", %{
          "messenger" => %{"provider" => "Signal", "value" => "https://Signal.me/#eu/aB3-_xY"}
        })

      assert redirected_to(conn) == ~p"/settings/messengers"

      assert [%Messenger{provider: "Signal", value: "https://signal.me/#eu/aB3-_xY"}] =
               all_for(user)
    end

    test "saves a Threema handle", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/settings/messengers", %{
        "messenger" => %{"provider" => "Threema", "value" => "abcd1234"}
      })

      assert [%Messenger{provider: "Threema", value: "ABCD1234"}] = all_for(user)
    end
  end

  describe "GET /:slug/messengers" do
    test "renders each entry as a click-to-chat deep link", %{conn: conn} do
      owner = insert_activated_user()
      insert(:messenger, user: owner, provider: "Telegram", value: "ada_lovelace")
      insert(:messenger, user: owner, provider: "WhatsApp", value: "+49 261 123456")

      html = conn |> get(~p"/#{owner}/messengers") |> html_response(200)

      assert html =~ "https://t.me/ada_lovelace"
      assert html =~ "https://wa.me/49261123456"
    end

    test "is served as agent-format siblings too", %{conn: conn} do
      owner = insert_activated_user()
      insert(:messenger, user: owner, provider: "Telegram", value: "ada_lovelace")

      # Extension URLs are handled by the AgentFormat plug, not explicit routes,
      # so they are built as plain strings (like agent_docs_drift_test.exs).
      base = "/#{owner.username}/messengers"
      assert get(conn, base <> ".json").resp_body =~ "https://t.me/ada_lovelace"
      assert get(conn, base <> ".md").resp_body =~ "t.me/ada_lovelace"
    end
  end

  describe "a Signal contact link (issue #1442)" do
    @link "https://signal.me/#eu/aB3-_xY"

    test "reads as an action, never as its token", %{conn: conn} do
      owner = insert_activated_user()
      insert(:messenger, user: owner, provider: "Signal", value: @link)

      html = conn |> get(~p"/#{owner}/messengers") |> html_response(200)

      # The href is the link; the words the reader sees are not its 64 characters.
      assert html =~ ~s|href="https://signal.me/#eu/aB3-_xY"|
      assert html =~ "Open chat"
      refute html =~ ">https://signal.me"
    end

    test "the plain-text sibling prints the link once, not as its own label", %{conn: conn} do
      owner = insert_activated_user()
      insert(:messenger, user: owner, provider: "Signal", value: @link)

      body = get(conn, "/#{owner.username}/messengers.txt").resp_body

      assert body =~ "* Signal: #{@link}\n"
      refute body =~ "(#{@link})"
    end

    test "the JSON sibling says which address shape it is", %{conn: conn} do
      owner = insert_activated_user()
      insert(:messenger, user: owner, provider: "Signal", value: @link)

      body = get(conn, "/#{owner.username}/messengers.json").resp_body

      assert %{"entries" => [%{"kind" => "link", "url" => @link}]} = Jason.decode!(body)
    end
  end

  describe "the owner's editor" do
    test "GET /settings/messengers renders the manage page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert conn |> get(~p"/settings/messengers") |> html_response(200) =~ "Add a messenger"
    end

    test "a link filed under Links is offered a move, an ordinary page is not", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      messenger_link = insert(:url, user: user, value: "https://signal.me/#eu/aB3")
      webpage = insert(:url, user: user, value: "https://example.org/")

      html = conn |> get(~p"/settings/links") |> html_response(200)

      assert html =~ ~p"/settings/messengers/new?#{[from_link: messenger_link.id]}"
      refute html =~ ~p"/settings/messengers/new?#{[from_link: webpage.id]}"
    end

    test "the offered form is seeded from the member's own stored link", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      url = insert(:url, user: user, value: "https://Signal.me/#eu/aB3")

      html =
        conn
        |> get(~p"/settings/messengers/new?#{[from_link: url.id]}")
        |> html_response(200)

      assert html =~ ~s|value="https://signal.me/#eu/aB3"|
      # A prefilled form opens clean, it does not open scolding.
      refute html =~ "fields marked in red"
    end

    test "a link belonging to somebody else cannot seed the form", %{conn: conn} do
      stranger = insert_activated_user()
      url = insert(:url, user: stranger, value: "https://signal.me/#eu/aB3")
      {conn, _user} = create_and_login_user(conn)

      assert_raise Ecto.NoResultsError, fn ->
        get(conn, ~p"/settings/messengers/new?#{[from_link: url.id]}")
      end
    end
  end

  # vutuv is a German site; the whole section must be German for a `de` visitor
  # (locale is a test dimension). Guards against an English island slipping in.
  describe "German localization (issue #949)" do
    test "the new-messenger form renders in German", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/messengers/new")
        |> html_response(200)

      assert html =~ "Messenger auswählen"
    end

    test "the key labels have German translations" do
      Gettext.put_locale(@backend, "de")

      assert Gettext.gettext(@backend, "Add a messenger") == "Messenger hinzufügen"
      assert Gettext.gettext(@backend, "Select a messenger") == "Messenger auswählen"

      assert Gettext.gettext(@backend, "Messenger created successfully.") ==
               "Messenger wurde erstellt."
    end

    test "the contact-link wording is German too (issue #1442)" do
      Gettext.put_locale(@backend, "de")

      assert Gettext.gettext(@backend, "Open chat") == "Chat öffnen"

      assert Gettext.gettext(@backend, "Add this under Messengers") ==
               "Unter Messenger eintragen"

      refute Gettext.gettext(
               @backend,
               "Signal also takes its contact link (https://signal.me/#…). It names neither your phone number nor your username, and you can reset it in Signal at any time."
             ) =~ "Signal also takes"
    end
  end
end
