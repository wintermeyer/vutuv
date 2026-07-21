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

  describe "the owner's editor" do
    test "GET /settings/messengers renders the manage page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert conn |> get(~p"/settings/messengers") |> html_response(200) =~ "Add a messenger"
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
  end
end
