defmodule VutuvWeb.ModerationCaseControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Moderation
  alias Vutuv.Moderation.Case

  # The logged-in member owns a reported (frozen) post with an open case.
  defp owner_with_case(conn) do
    {conn, owner} = create_and_login_user(conn)
    post = insert(:post, user: owner)
    reporter = insert(:activated_user)
    {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "family"})
    {conn, owner, post, case_record}
  end

  describe "index" do
    test "lists my open cases", %{conn: conn} do
      {conn, _owner, _post, case_record} = owner_with_case(conn)

      conn = get(conn, ~p"/moderation/cases")
      response = html_response(conn, 200)
      assert response =~ case_record.id
    end

    test "requires login", %{conn: conn} do
      conn = get(conn, ~p"/moderation/cases")
      assert redirected_to(conn) == "/"
    end
  end

  describe "show" do
    test "the owner sees the case with the three ways out", %{conn: conn} do
      {conn, _owner, _post, case_record} = owner_with_case(conn)

      conn = get(conn, ~p"/moderation/cases/#{case_record.id}")
      response = html_response(conn, 200)
      assert response =~ "hidden"
      assert response =~ ~p"/moderation/cases/#{case_record.id}/dispute"
      assert response =~ ~p"/moderation/cases/#{case_record.id}/delete_content"
      assert response =~ ~p"/posts/#{case_record.content_id}/edit"
    end

    test "another member gets a 404", %{conn: conn} do
      {_conn, _owner, _post, case_record} = owner_with_case(conn)

      # Drain the owner-notification email so the next login_via_pin reads
      # its own PIN mail, not the moderation notice.
      flush_emails()

      {other_conn, _other} =
        create_and_login_user(build_conn() |> Plug.Test.init_test_session(%{}), %{
          "emails" => %{"0" => %{"value" => "other@example.com"}},
          "first_name" => "other"
        })

      conn = get(other_conn, ~p"/moderation/cases/#{case_record.id}")
      assert html_response(conn, 404)
    end
  end

  describe "dispute" do
    test "escalates the case and keeps the content frozen", %{conn: conn} do
      {conn, _owner, post, case_record} = owner_with_case(conn)

      conn = post(conn, ~p"/moderation/cases/#{case_record.id}/dispute")

      assert redirected_to(conn) == ~p"/moderation/cases/#{case_record.id}"
      assert Repo.get!(Case, case_record.id).status == "escalated"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end
  end

  describe "delete_content" do
    test "deletes the reported post and closes the case", %{conn: conn} do
      {conn, _owner, post, case_record} = owner_with_case(conn)

      conn = post(conn, ~p"/moderation/cases/#{case_record.id}/delete_content")

      assert redirected_to(conn) == ~p"/moderation/cases/#{case_record.id}"
      refute Repo.get(Vutuv.Posts.Post, post.id)
      assert Repo.get!(Case, case_record.id).status == "resolved_deleted"
    end

    test "deletes a reported message too", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      other = insert(:activated_user)
      conversation = insert_conversation_between(owner, other)
      message = insert(:message, conversation: conversation, sender: owner)
      {:ok, case_record} = Moderation.report_content(other, message, %{"category" => "bullying"})

      conn = post(conn, ~p"/moderation/cases/#{case_record.id}/delete_content")

      assert redirected_to(conn) == ~p"/moderation/cases/#{case_record.id}"
      refute Repo.get(Vutuv.Chat.Message, message.id)
      assert Repo.get!(Case, case_record.id).status == "resolved_deleted"
    end
  end
end
