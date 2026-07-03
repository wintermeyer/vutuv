defmodule VutuvWeb.ExportControllerTest do
  @moduledoc """
  The personal data export (GDPR Art. 20): the owner downloads one JSON file
  with everything vutuv stores about them. Strictly owner-only — the export
  contains private data (all email addresses, direct messages).
  """
  use VutuvWeb.ConnCase

  import Vutuv.ChatHelpers
  import Vutuv.PostsHelpers

  @login %{
    "emails" => %{"0" => %{"value" => "exporter@example.com"}},
    "first_name" => "Erika",
    "last_name" => "Beispiel",
    "gender" => "female",
    "tag_list" => @registration_tags
  }

  defp download(conn, _user) do
    get(conn, ~p"/settings/export/download")
  end

  test "the owner downloads one JSON file with their data", %{conn: conn} do
    {conn, user} = create_and_login_user(conn, @login)

    # Some content across the subsystems the export must cover.
    post = create_post!(user, %{body: "My exported thoughts"})
    follower = insert(:activated_user)
    insert(:follow, follower: follower, followee: user)
    other = insert(:activated_user)
    conversation = insert_conversation_between(user, other)
    send!(user, conversation, "hello from me")

    conn = download(conn, user)

    assert response_content_type(conn, :json) =~ "application/json"

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ user.username

    data = Jason.decode!(conn.resp_body)
    assert data["profile"]["username"] == user.username
    assert data["profile"]["first_name"] == "Erika"
    assert Enum.any?(data["emails"], &(&1["value"] == "exporter@example.com"))
    assert Enum.any?(data["posts"], &(&1["body"] == "My exported thoughts"))
    assert Enum.any?(data["posts"], &(&1["id"] == post.id))
    assert Enum.any?(data["followers"], &(&1["username"] == follower.username))

    assert [conversation_doc] = data["conversations"]
    assert Enum.any?(conversation_doc["messages"], &(&1["body"] == "hello from me"))
    assert data["schema_version"]
  end

  test "a guest is sent to the login flow, not the export", %{conn: conn} do
    # /settings is user-agnostic and login-required: there is no URL for
    # someone ELSE's export any more, and a guest is turned away.
    assert conn |> get(~p"/settings/export/download") |> redirected_to() == "/"
  end

  test "logged out is refused", %{conn: conn} do
    owner = insert(:activated_user)
    insert(:email, user: owner)

    conn = download(conn, owner)

    refute conn.status == 200
  end
end
