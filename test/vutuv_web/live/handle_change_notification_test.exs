defmodule VutuvWeb.HandleChangeNotificationTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts

  describe "handle-change notification on /notifications" do
    test "shows the before/after handles, the label, and links the rewritten post", %{conn: conn} do
      {conn, author} = create_and_login_user(conn)
      victim = insert(:user, username: "oldname")
      post = insert(:post, user: author, body: "great work @oldname keep going")

      {:ok, _} = Accounts.update_username(victim, %{"username" => "newname"})

      body = html_response(get(conn, ~p"/notifications"), 200)

      # Before/after handles are spelled out in the notification text.
      assert body =~ "changed their handle from @oldname to @newname"
      assert body =~ "Handle change"
      # The affected post is quoted with its rewritten body and links to its permalink.
      assert body =~ "great work @newname keep going"
      assert body =~ ~s(href="/#{author.username}/posts/#{post.id}")
    end

    test "counts the extra posts beyond the shown five", %{conn: conn} do
      {conn, author} = create_and_login_user(conn)
      victim = insert(:user, username: "oldname")
      for i <- 1..7, do: insert(:post, user: author, body: "post #{i} for @oldname")

      {:ok, _} = Accounts.update_username(victim, %{"username" => "newname"})

      {:ok, live, _html} = live(conn, ~p"/notifications")
      # Seven posts, five shown -> "and 2 more".
      assert render(live) =~ "and 2 more"
    end
  end
end
