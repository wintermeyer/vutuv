defmodule VutuvWeb.UserTagControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Tags.UserTag

  defp tag_count(user),
    do: Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^user.id), :count)

  describe "create (the one place tags are added — single or comma-separated)" do
    # The signed-up account already carries its three registration tags, so
    # every count below is relative to that baseline.
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user, base: tag_count(user)}
    end

    test "adds a single tag and redirects to the tags page", %{
      conn: conn,
      user: user,
      base: base
    } do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: "Elixir"})

      assert redirected_to(conn) == ~p"/#{user}/tags"
      assert tag_count(user) == base + 1
    end

    test "adds several comma- or space-separated tags at once", %{
      conn: conn,
      user: user,
      base: base
    } do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: "Elixir, Phoenix  Ruby"})

      assert redirected_to(conn) == ~p"/#{user}/tags"
      # Both the comma and the (doubled) space split, so this is three tags.
      assert tag_count(user) == base + 3
    end

    test "ignores empty segments between commas", %{conn: conn, user: user, base: base} do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: "Elixir, , Ruby,"})

      assert redirected_to(conn) == ~p"/#{user}/tags"
      assert tag_count(user) == base + 2
    end

    test "re-renders the form with an error when nothing usable is typed", %{
      conn: conn,
      user: user,
      base: base
    } do
      conn = post(conn, ~p"/#{user}/tags", tag_param: %{value: ""})

      assert html_response(conn, 200) =~ "editform"
      assert tag_count(user) == base
    end
  end

  # `UserTagController.resolve_slug` is a plug that runs before every action.
  # When the slug does not resolve to a user tag it must render a clean 404 and
  # *halt*: without the halt the pipeline falls through into `show/2` / `delete/2`
  # with `conn.assigns[:user_tag] == nil`, which crashes (500 / double render)
  # instead of returning the 404. Every sibling resolver halts on the nil
  # branch, so this controller must too.

  describe "resolve_slug on an unknown user-tag slug" do
    setup %{conn: conn} do
      user = insert_activated_user()
      {:ok, conn: conn, user: user}
    end

    test "GET show returns a clean 404 instead of falling through", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}/tags/does-not-exist")

      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "resolve_slug on an unknown user-tag slug for a logged-in user" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "DELETE returns a clean 404 instead of crashing", %{conn: conn, user: user} do
      conn = delete(conn, ~p"/#{user}/tags/does-not-exist")

      assert conn.status == 404
      assert conn.halted
    end
  end

  # The public endorser list behind the profile Tags popover's "and N more"
  # link: everyone who currently endorses this member for this tag.
  describe "endorsers" do
    setup do
      owner = insert_activated_user(username: "tag_owner")
      tag = insert(:tag, name: "Ruby", slug: "ruby")
      user_tag = insert(:user_tag, user: owner, tag: tag)
      {:ok, owner: owner, tag: tag, user_tag: user_tag}
    end

    test "lists the visible endorsers (no login required)", %{
      conn: conn,
      owner: owner,
      user_tag: user_tag
    } do
      endorser = insert_activated_user(first_name: "Rick", last_name: "Sanchez")
      insert(:user_tag_endorsement, user_tag: user_tag, user: endorser)

      html = conn |> get(~p"/#{owner}/tags/ruby/endorsers") |> html_response(200)

      assert html =~ "Rick Sanchez"
      assert html =~ "Ruby"
    end

    test "the per-row follow icon names itself (title + aria-label)", %{
      conn: conn,
      owner: owner,
      user_tag: user_tag
    } do
      # This table keeps the compact icon-only follow control, so it must carry
      # an accessible name (hover tooltip + screen-reader label), like the mute
      # bell does — otherwise the glyph is a mystery button.
      {conn, _viewer} = create_and_login_user(conn)
      endorser = insert_activated_user(first_name: "Rick", last_name: "Sanchez")
      insert(:user_tag_endorsement, user_tag: user_tag, user: endorser)

      html = conn |> get(~p"/#{owner}/tags/ruby/endorsers") |> html_response(200)

      # The viewer does not follow the endorser, so the row offers "Follow".
      assert html =~ ~s(title="Follow")
      assert html =~ ~s(aria-label="Follow")
    end

    test "shows when each endorsement was cast", %{
      conn: conn,
      owner: owner,
      user_tag: user_tag
    } do
      endorser = insert_activated_user(first_name: "Rick", last_name: "Sanchez")
      endorsement = insert(:user_tag_endorsement, user_tag: user_tag, user: endorser)

      html = conn |> get(~p"/#{owner}/tags/ruby/endorsers") |> html_response(200)

      # The label plus a client-localized <time> (the server text is the no-JS
      # fallback; app.js rewrites it to the viewer's locale).
      assert html =~ "Endorsed"
      assert html =~ "data-localtime"
      assert html =~ Calendar.strftime(endorsement.inserted_at, "%Y-%m-%d")
    end

    test "drops hidden / unconfirmed endorsers from the list (issue #783)", %{
      conn: conn,
      owner: owner,
      user_tag: user_tag
    } do
      visible = insert_activated_user(first_name: "Vee", last_name: "Visible")
      insert(:user_tag_endorsement, user_tag: user_tag, user: visible)

      # An unconfirmed account (email_confirmed? == false) is not publicly
      # visible, so it must not appear in (or inflate) the list.
      hidden = insert(:user, first_name: "Han", last_name: "Hidden")
      insert(:user_tag_endorsement, user_tag: user_tag, user: hidden)

      html = conn |> get(~p"/#{owner}/tags/ruby/endorsers") |> html_response(200)

      assert html =~ "Vee Visible"
      refute html =~ "Han Hidden"
    end

    test "an unknown tag returns a clean 404 and halts", %{conn: conn, owner: owner} do
      conn = get(conn, ~p"/#{owner}/tags/does-not-exist/endorsers")

      assert conn.status == 404
      assert conn.halted
    end

    test "is sortable by name, username and date", %{conn: conn, owner: owner, user_tag: user_tag} do
      zoe = insert_activated_user(first_name: "Zoe", last_name: "Adams", username: "zoe.adams")
      amy = insert_activated_user(first_name: "Amy", last_name: "Baker", username: "amy.baker")

      # zoe endorses first, amy second (UUID v7 ids are time-ordered).
      insert(:user_tag_endorsement, user_tag: user_tag, user: zoe)
      insert(:user_tag_endorsement, user_tag: user_tag, user: amy)

      # The .json sibling lists people in the same order the HTML table renders.
      names = fn query ->
        "/#{owner.username}/tags/ruby/endorsers.json?#{URI.encode_query(query)}"
        |> then(&get(conn, &1).resp_body)
        |> Jason.decode!()
        |> Map.fetch!("people")
        |> Enum.map(& &1["name"])
      end

      # By last name (then first name).
      assert names.(%{"sort" => "name", "dir" => "asc"}) == ["Zoe Adams", "Amy Baker"]
      assert names.(%{"sort" => "name", "dir" => "desc"}) == ["Amy Baker", "Zoe Adams"]
      # By username (username).
      assert names.(%{"sort" => "username", "dir" => "asc"}) == ["Amy Baker", "Zoe Adams"]
      # By date: default is newest endorsement first.
      assert names.(%{"sort" => "date", "dir" => "desc"}) == ["Amy Baker", "Zoe Adams"]
      assert names.(%{"sort" => "date", "dir" => "asc"}) == ["Zoe Adams", "Amy Baker"]
      # A bogus sort falls back to the default (date desc) rather than erroring.
      assert names.(%{"sort" => "bogus"}) == ["Amy Baker", "Zoe Adams"]
    end

    test "paginates the HTML list and keeps the sort across pages", %{
      conn: conn,
      owner: owner,
      user_tag: user_tag
    } do
      for _ <- 1..(Vutuv.Tags.endorsers_per_page() + 1) do
        insert(:user_tag_endorsement, user_tag: user_tag, user: insert_activated_user())
      end

      html =
        conn |> get(~p"/#{owner}/tags/ruby/endorsers?sort=name&dir=asc") |> html_response(200)

      # A second page exists and its link carries the active sort.
      assert html =~ "page=2"
      assert html =~ "sort=name"
    end
  end
end
