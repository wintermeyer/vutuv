defmodule VutuvWeb.ModerationCaseControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Moderation
  alias Vutuv.Moderation.Case
  alias Vutuv.Organizations

  # An open case on a post published in a **page's** name, with `member` holding
  # `role` on that page. The case is carried by the member who claimed the page,
  # never by `member` (issue #2120).
  defp page_post_case(member, role \\ "owner") do
    claimer = insert(:activated_user)
    organization = insert(:organization, created_by_user_id: claimer.id)
    {:ok, _} = Organizations.add_role(organization, claimer, "owner", claimer)
    {:ok, _} = Organizations.add_role(organization, member, role, claimer)

    post = insert(:post, user: nil, organization: organization)
    reporter = insert(:activated_user)
    {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "family"})

    {organization, case_record}
  end

  # The logged-in member owns a reported (frozen) post with an open case.
  defp owner_with_case(conn, attrs \\ %{"category" => "family"}) do
    {conn, owner} = create_and_login_user(conn)
    post = insert(:post, user: owner)
    reporter = insert(:activated_user)
    {:ok, case_record} = Moderation.report_content(reporter, post, attrs)
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

    test "a copyright case keeps delete and dispute but drops the edit promise", %{conn: conn} do
      {conn, _owner, _post, case_record} =
        owner_with_case(conn, %{
          "category" => "copyright",
          "note" => "The photo is mine, the original is at example.com/photo",
          "good_faith?" => "true"
        })

      response = conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert response =~ ~p"/moderation/cases/#{case_record.id}/dispute"
      assert response =~ ~p"/moderation/cases/#{case_record.id}/delete_content"
      # The edit is still offered, but it no longer promises the post back.
      assert response =~ ~p"/posts/#{case_record.content_id}/edit"
      refute response =~ "An edited post is visible again immediately."
      assert response =~ "stays hidden until they have"
    end

    test "carries the statement of reasons: the words, the ground, the deadline", %{conn: conn} do
      {conn, _owner, _post, case_record} =
        owner_with_case(conn, %{
          "category" => "bullying",
          "note" => "This names my colleague and calls her a liar."
        })

      response = conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert response =~ "This names my colleague and calls her a liar."
      assert response =~ "No person made this decision"
      assert response =~ "Our community guidelines"
      assert response =~ "72 hours"
    end

    test "a copyright case names the law as the ground", %{conn: conn} do
      {conn, _owner, _post, case_record} =
        owner_with_case(conn, %{
          "category" => "copyright",
          "note" => "The photo is mine, the original is at example.com/photo",
          "good_faith?" => "true"
        })

      response = conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert response =~ "Copyright law."
      refute response =~ "Our community guidelines, which everything"
    end

    test "a reported message is not offered an edit it does not have", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      other = insert(:activated_user)
      conversation = insert_conversation_between(owner, other)
      message = insert(:message, conversation: conversation, sender: owner)

      {:ok, case_record} =
        Moderation.report_content(other, message, %{"category" => "bullying", "note" => "Stop."})

      response = conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert response =~ "Stop."
      assert response =~ ~p"/moderation/cases/#{case_record.id}/delete_content"
      refute response =~ "/edit"
    end

    test "reads in German for a German member", %{conn: conn} do
      {conn, owner, _post, case_record} = owner_with_case(conn, %{"category" => "spam"})
      owner |> Ecto.Changeset.change(locale: "de") |> Repo.update!()

      response =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/moderation/cases/#{case_record.id}")
        |> html_response(200)

      assert response =~ "Diese Entscheidung hat kein Mensch getroffen"
      assert response =~ "Grundlage"
      assert response =~ "Unsere Verhaltensregeln"
    end

    # Issue #2120. The case is carried by the member who claimed the page, and
    # every other owner is told about it — so they may read it, and the page
    # must not offer them controls that would 404 when pressed.
    test "an owner of the page reads the case, without being offered the way out",
         %{conn: conn} do
      {conn, co_owner} = create_and_login_user(conn)
      {organization, case_record} = page_post_case(co_owner)

      response = conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(200)

      assert response =~ organization.name
      refute response =~ "Your content was reported"
      refute response =~ ~p"/moderation/cases/#{case_record.id}/dispute"
      refute response =~ ~p"/moderation/cases/#{case_record.id}/delete_content"
      assert response =~ "Answering the report is up to the member who claimed the page"
    end

    test "and pressing the way out anyway is still a 404", %{conn: conn} do
      {conn, co_owner} = create_and_login_user(conn)
      {_organization, case_record} = page_post_case(co_owner)

      assert conn
             |> post(~p"/moderation/cases/#{case_record.id}/dispute")
             |> html_response(404)
    end

    test "and reads in German for a German owner", %{conn: conn} do
      {conn, co_owner} = create_and_login_user(conn)
      {organization, case_record} = page_post_case(co_owner)
      co_owner |> Ecto.Changeset.change(locale: "de") |> Repo.update!()

      response =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/moderation/cases/#{case_record.id}")
        |> html_response(200)

      assert response =~ "Ein Inhalt von #{organization.name} wurde gemeldet"
      assert response =~ "Auf die Meldung antworten kann nur das Mitglied"
      assert response =~ "Verborgen, solange der Fall offen ist."
      # The member-voiced sentence gettext fuzzy-filled these msgids with.
      refute response =~ "Sie können das selbst klären"
    end

    test "a publisher on the same page gets a 404", %{conn: conn} do
      {conn, publisher} = create_and_login_user(conn)
      {_organization, case_record} = page_post_case(publisher, "publisher")

      assert conn |> get(~p"/moderation/cases/#{case_record.id}") |> html_response(404)
    end

    test "another member gets a 404", %{conn: conn} do
      {_conn, _owner, _post, case_record} = owner_with_case(conn)

      # Drain the owner-notification email so the next login_via_pin reads
      # its own PIN mail, not the moderation notice.
      flush_emails()

      {other_conn, _other} =
        create_and_login_user(build_conn() |> Plug.Test.init_test_session(%{}), %{
          "emails" => %{"0" => %{"value" => "other@example.com"}},
          "first_name" => "other",
          "tag_list" => @registration_tags
        })

      conn = get(other_conn, ~p"/moderation/cases/#{case_record.id}")
      assert html_response(conn, 404)
    end
  end

  describe "image" do
    # Every neighbouring action resolves the id through
    # `Vutuv.UUIDv7.with_cast/2`, so a typo in the URL is a miss. This one read
    # it straight, where a malformed id raises `Ecto.Query.CastError` — a 400
    # and an exception in the log for what is plainly a wrong address
    # (issue #2031).
    test "a malformed case id is a 404, like every other action", %{conn: conn} do
      {conn, _owner, _post, _case} = owner_with_case(conn)

      conn = get(conn, "/moderation/cases/not-a-uuid/image")
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
