defmodule VutuvWeb.ReportControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Moderation
  alias Vutuv.Moderation.Case

  setup %{conn: conn} do
    author = insert_activated_user()
    post = insert(:post, user: author)
    {:ok, %{conn: conn, author: author, post: post}}
  end

  describe "new" do
    test "renders the report form with the four categories", %{conn: conn, post: post} do
      {conn, _me} = create_and_login_user(conn)
      conn = get(conn, ~p"/reports/new?type=post&id=#{post.id}")

      response = html_response(conn, 200)
      assert response =~ "Report"
      assert response =~ "family"
      assert response =~ "bullying"
      assert response =~ "spam"
      # linked house rules
      assert response =~ "/community"
      # No standing relationship: the report really is anonymous, say so,
      # and there is no separation to warn about.
      assert response =~ "Your report is anonymous."
      refute response =~ "report-severance-notice"
    end

    test "warns a connected reporter about the separation before sending", %{
      conn: conn,
      author: author,
      post: post
    } do
      {conn, me} = create_and_login_user(conn)
      connect!(Repo.get!(Vutuv.Accounts.User, me.id), author)

      response = conn |> get(~p"/reports/new?type=post&id=#{post.id}") |> html_response(200)

      # The consequence, the why, the de-facto loss of anonymity, the undo -
      # all spelled out before the reporter commits.
      assert response =~ "report-severance-notice"
      assert response =~ "@#{author.username}"
      assert response =~ "paused in both directions"
      assert response =~ "may recognize"
      assert response =~ "unfounded"
      # The blanket anonymity promise would be wrong here.
      refute response =~ "Your report is anonymous."
    end

    test "requires login", %{conn: conn, post: post} do
      conn = get(conn, ~p"/reports/new?type=post&id=#{post.id}")
      assert redirected_to(conn) == "/"
    end

    test "does not append an ellipsis to an umlaut-heavy body within the grapheme cap", %{
      conn: conn,
      author: author
    } do
      # 200 graphemes but 400 bytes: comfortably under the 280-grapheme preview
      # cap, yet over 280 bytes. The old `byte_size <= 280` guard mis-classified
      # it as too long, sliced it (a no-op, since it is already shorter) and
      # tacked on a spurious "…". A grapheme-based cap must leave it whole.
      body = String.duplicate("ä", 200)
      post = insert(:post, user: author, body: body)

      {conn, _me} = create_and_login_user(conn)

      response =
        conn |> get(~p"/reports/new?type=post&id=#{post.id}") |> html_response(200)

      assert response =~ body
      refute response =~ body <> "…"
    end

    test "does not preview a private message the reporter is not party to", %{conn: conn} do
      alice = insert_activated_user()
      bob = insert_activated_user()
      conversation = insert_conversation_between(alice, bob)
      message = insert(:message, conversation: conversation, sender: alice)

      {conn, _reporter} = create_and_login_user(conn)
      conn = get(conn, ~p"/reports/new?type=message&id=#{message.id}")

      # A non-participant must not see the message body previewed — the same
      # authorization the create path enforces now gates the form too.
      assert conn.status == 404
    end

    test "404s for unknown content", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      conn = get(conn, ~p"/reports/new?type=post&id=#{Vutuv.UUIDv7.generate()}")
      assert html_response(conn, 404)
    end
  end

  describe "create" do
    test "files the report and freezes the post", %{conn: conn, post: post} do
      {conn, _me} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{
            "type" => "post",
            "id" => post.id,
            "category" => "bullying",
            "note" => "mean"
          }
        })

      assert redirected_to(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Thank you"
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
      assert %Case{status: "pending_owner"} = Repo.one(Case)
    end

    test "explains the protective separation when a relationship existed", %{
      conn: conn,
      author: author,
      post: post
    } do
      {conn, me} = create_and_login_user(conn)
      connect!(Repo.get!(Vutuv.Accounts.User, me.id), author)

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{"type" => "post", "id" => post.id, "category" => "bullying"}
        })

      flash = Phoenix.Flash.get(conn.assigns.flash, :info)
      # The reporter learns: separated both ways, undone if the report is
      # found unfounded.
      assert flash =~ "paused"
      assert flash =~ "either"
      assert flash =~ "unfounded"
    end

    test "reporting your own content is refused", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      my_post = insert(:post, user: me)

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{"type" => "post", "id" => my_post.id, "category" => "spam"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      refute Repo.get!(Vutuv.Posts.Post, my_post.id).frozen_at
    end

    test "a duplicate report is acknowledged without a second case", %{conn: conn, post: post} do
      {conn, me} = create_and_login_user(conn)
      {:ok, _} = Moderation.report_content(me, post, %{"category" => "spam"})

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{"type" => "post", "id" => post.id, "category" => "spam"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "already"
      assert Repo.aggregate(Case, :count) == 1
    end

    test "a whole profile can be reported", %{conn: conn, author: author} do
      {conn, _me} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{"type" => "user", "id" => author.id, "category" => "bullying"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Thank you"
      assert %Case{content_type: "user", status: "flagged"} = Repo.one(Case)
    end

    test "reporting a profile reassures the reporter that moderators will review it", %{
      conn: conn,
      author: author
    } do
      {conn, _me} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{"type" => "user", "id" => author.id, "category" => "spam"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "moderators"
    end
  end
end
