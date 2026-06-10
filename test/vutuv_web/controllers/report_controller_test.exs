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
    end

    test "requires login", %{conn: conn, post: post} do
      conn = get(conn, ~p"/reports/new?type=post&id=#{post.id}")
      assert redirected_to(conn) == "/"
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
  end
end
