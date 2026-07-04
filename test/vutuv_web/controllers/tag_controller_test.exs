defmodule VutuvWeb.TagControllerTest do
  use VutuvWeb.ConnCase, async: true

  # The public tag pages resolve the `:slug` param to a `Tags.Tag` before every
  # action. An unknown slug must render a clean 404 and *halt* (a missing tag
  # must not fall through into `show/2` with a nil assign). The `:index` action
  # carries no `:slug` param, so the resolver must pass through cleanly there and
  # still render the listing. These guard the swap to the shared resolver plug.

  describe "index (no slug param)" do
    test "renders the tag listing", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")
      conn = get(conn, ~p"/tags")
      assert conn.status == 200
    end
  end

  describe "show" do
    test "renders an existing tag", %{conn: conn} do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      conn = get(conn, ~p"/tags/#{tag}")
      assert conn.status == 200
    end

    test "returns a clean 404 on an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/tags/does-not-exist")
      assert conn.status == 404
      assert conn.halted
    end
  end

  # Issue #844: the "Add this tag" button on a tag page posted to the retired
  # /:slug/tags URL, which serves only GET, so a logged-in visitor clicking it
  # got a 404 instead of the tag landing on their profile. The button renders
  # through Phoenix's button/2 helper (a data-to + data-method="post" element),
  # so assert the target it actually submits to, not just the create route.
  describe "the \"Add this tag\" button (logged-in visitor without the tag)" do
    test "posts to /settings/tags, not /:slug/tags", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:tag, name: "Elixir", slug: "elixir")

      html = conn |> get(~p"/tags/elixir") |> html_response(200)

      assert html =~ "Add this tag"
      assert html =~ ~s(data-to="/settings/tags?tag_param[value]=Elixir")
      assert html =~ ~s(data-method="post")
      refute html =~ ~s(data-to="/#{user.username}/tags)
    end
  end
end
