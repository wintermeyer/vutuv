defmodule VutuvWeb.ReportControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Moderation
  alias Vutuv.Moderation.Case

  # Both members must be logged in before a freeze fires its owner-notification
  # email, so each login PIN is still the newest mail; each needs its own
  # session-initialised conn (see the ConnCase setup).
  defp fresh_conn, do: Plug.Test.init_test_session(build_conn(), %{})

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

    test "a bystander cannot preview frozen content once a case is open, but the author can" do
      {author_conn, author} = create_and_login_user(fresh_conn())
      {bystander_conn, _bystander} = create_and_login_user(fresh_conn())

      post = insert(:post, user: author)

      # A trusted reporter freezes the post and opens a moderation case; the
      # permalink now 404s for everyone but the author and admins.
      {:ok, _} = Moderation.report_content(insert_activated_user(), post, %{"category" => "spam"})
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at

      # F10: a bystander with no tie to the open case must not get the form. The
      # open case alone used to render the preview to any logged-in member.
      assert bystander_conn
             |> get(~p"/reports/new?type=post&id=#{post.id}")
             |> html_response(404)

      # The author can see their own frozen post, so the gate still admits them.
      assert author_conn
             |> get(~p"/reports/new?type=post&id=#{post.id}")
             |> html_response(200)
    end

    test "offers the copyright notice with its good-faith box", %{conn: conn, post: post} do
      {conn, _me} = create_and_login_user(conn)

      response =
        conn |> get(~p"/reports/new?type=post&id=#{post.id}") |> html_response(200)

      assert response =~ ~s(value="copyright")
      assert response =~ "without the rights holder&#39;s permission"
      # The declaration and the "which work, where is the original" prompt are
      # in the markup and revealed by CSS, so the form needs no JavaScript.
      assert response =~ ~s(name="report[good_faith?]")
      assert response =~ "report-good-faith"
      assert response =~ "where can the original be seen"
    end

    test "a private message report does not offer it", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      alice = insert_activated_user()
      me = Repo.get!(Vutuv.Accounts.User, me.id)
      conversation = insert_conversation_between(alice, me)
      message = insert(:message, conversation: conversation, sender: alice)

      response =
        conn |> get(~p"/reports/new?type=message&id=#{message.id}") |> html_response(200)

      # Nothing was published, so there is nothing to have taken down.
      refute response =~ ~s(value="copyright")
      refute response =~ "report-good-faith"
    end

    test "renders the copyright option in German", %{conn: conn, post: post} do
      {conn, _me} = create_and_login_user(conn)

      response =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/reports/new?type=post&id=#{post.id}")
        |> html_response(200)

      assert response =~ "ohne Erlaubnis"
      assert response =~ "nach bestem Wissen"
      assert response =~ "Um welches Werk geht es"
    end

    test "a reporter tied to the open case still reaches the form", %{conn: conn} do
      {conn, reporter} = create_and_login_user(conn)
      author = insert_activated_user()
      post = insert(:post, user: author)

      # Filing the report freezes the post and ties the reporter to the case.
      {:ok, _} = Moderation.report_content(reporter, post, %{"category" => "spam"})
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at

      # The frozen post is no longer otherwise visible to them, but their own
      # report on the open case keeps the form reachable.
      assert conn
             |> get(~p"/reports/new?type=post&id=#{post.id}")
             |> html_response(200)
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

    # The `new` action has refused a bystander since #F10, but `create` never
    # shared the gate: an open case made the visibility check unreachable for
    # *everyone*, so a member the author had blocked could still file — and a
    # trusted reporter's report is what upgrades a flagged case and freezes the
    # content. The form 404ing while the POST behind it worked is the whole bug.
    test "a bystander cannot file on an open case they could not see" do
      {_author_conn, author} = create_and_login_user(fresh_conn())
      {bystander_conn, bystander} = create_and_login_user(fresh_conn())

      post = insert(:post, user: author)
      {:ok, _} = Vutuv.Social.block_user(author, bystander)

      {:ok, _} = Moderation.report_content(insert_activated_user(), post, %{"category" => "spam"})
      cases_before = Repo.aggregate(Case, :count)

      assert bystander_conn
             |> post(~p"/reports", %{
               "report" => %{"type" => "post", "id" => post.id, "category" => "spam"}
             })
             |> response(404)

      assert Repo.aggregate(Case, :count) == cases_before
    end

    test "an incomplete copyright notice comes back with the note intact", %{
      conn: conn,
      post: post
    } do
      {conn, _me} = create_and_login_user(conn)
      note = "The photo is mine, the original is at example.com/photo"

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{
            "type" => "post",
            "id" => post.id,
            "category" => "copyright",
            "note" => note
          }
        })

      # A redirect + flash would throw the written explanation away, which is
      # the one thing a copyright notice cannot afford to lose.
      response = html_response(conn, 422)
      assert response =~ "good faith"
      assert response =~ note
      assert Repo.aggregate(Case, :count) == 0
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "says in German what is missing", %{conn: conn, post: post} do
      {conn, _me} = create_and_login_user(conn)

      response =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> post(~p"/reports", %{
          "report" => %{"type" => "post", "id" => post.id, "category" => "copyright"}
        })
        |> html_response(422)

      # Both messages live in errors.po, reached through the extraction anchors
      # in VutuvWeb.ErrorHelpers - an untranslated banner would read English
      # here while every other line on the page is German.
      assert response =~ "Bitte sagen Sie uns, um welches Werk es geht"
      assert response =~ "nach bestem Wissen"
    end

    test "a complete copyright notice files the case", %{conn: conn, post: post} do
      {conn, _me} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/reports", %{
          "report" => %{
            "type" => "post",
            "id" => post.id,
            "category" => "copyright",
            "note" => "The photo is mine, the original is at example.com/photo",
            "good_faith?" => "true"
          }
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Thank you"
      assert %Case{status: "pending_owner"} = Repo.one(Case)
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
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
