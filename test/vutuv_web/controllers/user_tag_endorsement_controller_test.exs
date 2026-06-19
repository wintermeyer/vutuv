defmodule VutuvWeb.UserTagEndorsementControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Tags.UserTagEndorsement

  # This controller runs two guard plugs before every action:
  #
  #   * `resolve_slug` loads the user-tag id scoped to the *path user's* tags
  #     (an unknown / foreign slug 404s and halts), and
  #   * `require_user_logged_in` 404s (it deliberately does NOT redirect like the
  #     RequireLogin plug) when there is no session user.
  #
  # Both are copied verbatim across sibling controllers, so they get pulled into
  # shared plugs. These tests pin the externally observable behavior.

  describe "resolve_slug on an unknown user-tag slug" do
    test "create returns a clean 404 and stores nothing", %{conn: conn} do
      user = insert_activated_user()

      conn =
        post(conn, ~p"/#{user}/user_tag_endorsements", id: "does-not-exist")

      assert conn.status == 404
      assert conn.halted
      assert Repo.aggregate(UserTagEndorsement, :count) == 0
    end
  end

  describe "owner-scoping of the user-tag slug" do
    test "a tag belonging to another user does not resolve under this user", %{conn: conn} do
      user = insert_activated_user()
      other = insert_activated_user()
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      insert(:user_tag, user: other, tag: tag)

      conn =
        post(conn, ~p"/#{user}/user_tag_endorsements", id: tag.slug)

      assert conn.status == 404
      assert conn.halted
      assert Repo.aggregate(UserTagEndorsement, :count) == 0
    end
  end

  describe "require_user_logged_in" do
    test "create on a resolvable tag 404s when logged out (does not redirect)", %{conn: conn} do
      user = insert_activated_user()
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      insert(:user_tag, user: user, tag: tag)

      conn =
        post(conn, ~p"/#{user}/user_tag_endorsements", id: tag.slug)

      assert conn.status == 404
      assert conn.halted
      assert Repo.aggregate(UserTagEndorsement, :count) == 0
    end
  end

  # The profile's upvote pill toggles the endorsement over fetch (see the
  # `TagVote` enhancement in app.js): such a request carries an
  # `x-requested-with: fetch` header and gets the fresh count + state back as
  # JSON so the pill can animate in place without a reload. A plain (no-JS) form
  # submit still falls back to a flash + redirect, the way it always has.
  describe "AJAX toggle (x-requested-with: fetch)" do
    setup %{conn: conn} do
      {conn, endorser} = create_and_login_user(conn)
      owner = insert_activated_user()
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      user_tag = insert(:user_tag, user: owner, tag: tag)
      %{conn: conn, endorser: endorser, owner: owner, tag: tag, user_tag: user_tag}
    end

    # ConnTest's recycle/1 drops custom request headers, and post/3 recycles
    # again unless we recycle first, so set the AJAX header on an already-recycled
    # conn (same dance submit_with_csrf does for the CSRF token).
    defp ajax(conn) do
      conn |> recycle() |> put_req_header("x-requested-with", "fetch")
    end

    test "create returns the new count + endorsed=true as JSON", ctx do
      conn = post(ajax(ctx.conn), ~p"/#{ctx.owner}/user_tag_endorsements", id: ctx.tag.slug)

      assert json_response(conn, 200) == %{"count" => "1", "endorsed" => true}
      assert Repo.aggregate(UserTagEndorsement, :count) == 1
    end

    test "delete returns the decremented count + endorsed=false as JSON", ctx do
      insert(:user_tag_endorsement, user_tag: ctx.user_tag, user: ctx.endorser)

      conn = delete(ajax(ctx.conn), ~p"/#{ctx.owner}/user_tag_endorsements/#{ctx.tag.slug}")

      assert json_response(conn, 200) == %{"count" => "0", "endorsed" => false}
      assert Repo.aggregate(UserTagEndorsement, :count) == 0
    end

    test "without the header, create still redirects to the profile (no-JS path)", ctx do
      conn = post(recycle(ctx.conn), ~p"/#{ctx.owner}/user_tag_endorsements", id: ctx.tag.slug)

      assert redirected_to(conn) == ~p"/#{ctx.owner}"
      assert Repo.aggregate(UserTagEndorsement, :count) == 1
    end
  end
end
