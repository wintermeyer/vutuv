defmodule VutuvWeb.ExportControllerTest do
  @moduledoc """
  The member's export corner at /:slug/export (issue #841): the overview
  page offering the formatted CV and the GDPR Art. 20 data download, and
  the JSON file itself. Strictly owner-only — the export contains private
  data (all email addresses, direct messages).
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

  defp download(conn, user) do
    get(conn, ~p"/#{user}/export/download")
  end

  test "the overview page offers the CV and the data download", %{conn: conn} do
    {conn, user} = create_and_login_user(conn, @login)

    conn = get(conn, ~p"/#{user}/export")
    body = html_response(conn, 200)

    # Assert the rendered hrefs, not just the routes we know exist. The CV
    # lives at its own public URL now; the export page links to it.
    assert body =~ ~s(href="/#{user.username}/export/download")
    assert body =~ ~s(href="/#{user.username}/cv")
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

  test "another member gets the 403 page, never the export", %{conn: conn} do
    owner = insert(:activated_user)
    insert(:email, user: owner)
    {conn, _visitor} = create_and_login_user(conn)

    assert conn |> recycle() |> get(~p"/#{owner}/export") |> html_response(403)
    assert conn |> recycle() |> download(owner) |> html_response(403)
  end

  test "logged out is refused", %{conn: conn} do
    owner = insert(:activated_user)
    insert(:email, user: owner)

    conn = download(conn, owner)

    refute conn.status == 200
  end
end
