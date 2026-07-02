defmodule VutuvWeb.UrlControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.Profiles.Url

  test "show all urls", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/#{user}/links")
    assert html_response(conn, 200) =~ "html"
  end

  test "redirect when creating valid url", %{conn: conn} do
    {conn, user} = create_url(conn, "example.org")
    assert redirected_to(conn) == ~p"/#{user}/links"
    assert Repo.get_by(Url, value: "http://example.org", user_id: user.id)
  end

  test "return 422 when creating invalid url", %{conn: conn} do
    {conn, user} = create_url(conn, "invalid_url")
    assert html_response(conn, 422) =~ ~p"/#{user}/links"
    refute Repo.get_by(Url, value: "invalid_url", user_id: user.id)
  end

  test "return 422 when creating empty url", %{conn: conn} do
    {conn, user} = create_url(conn, "")
    assert html_response(conn, 422) =~ ~p"/#{user}/links"
  end

  test "redirect when setting valid url", %{conn: conn} do
    {conn, user, url} = set_url(conn, "example.org")
    assert redirected_to(conn) == ~p"/#{user}/links/#{url}"
    assert Repo.get(Url, url.id).value == "http://example.org"
  end

  test "return 422 when setting invalid url", %{conn: conn} do
    {conn, user, url} = set_url(conn, "invalid_url")
    assert html_response(conn, 422) =~ ~p"/#{user}/links/#{url}"
    refute Repo.get(Url, url.id).value == "invalid_url"
  end

  test "return 422 when setting empty url", %{conn: conn} do
    {conn, user, url} = set_url(conn, "")
    assert html_response(conn, 422) =~ ~p"/#{user}/links/#{url}"
  end

  test "breadcrumbs escape user-authored text instead of injecting raw HTML", %{conn: conn} do
    {_conn, user} = create_and_login_user(conn)
    # The link description lands as the final (bare-string) breadcrumb on the
    # public show page; it must be escaped there like everywhere else.
    url =
      insert(:url,
        user: user,
        value: "http://example.org",
        description: "<img src=x onerror=x>R&D"
      )

    html = build_conn() |> get(~p"/#{user}/links/#{url}") |> html_response(200)
    refute html =~ "<img src=x"
    assert html =~ "&lt;img src=x onerror=x&gt;R&amp;D"
  end

  test "the public show page neutralizes a legacy javascript: link instead of 500ing", %{
    conn: conn
  } do
    {_conn, user} = create_and_login_user(conn)
    # A row that predates the scheme validation (inserted straight, bypassing
    # the changeset) must still render as an inert link on the public page.
    url = insert(:url, user: user, value: "javascript://example.com/%0aalert(document.cookie)")

    # Anonymous visitor (no login): the show page is public. It must render
    # (no 500 from link/2's scheme guard) with the href neutralized — the raw
    # value may still appear as escaped link *text*, which is harmless.
    resp = get(build_conn(), ~p"/#{user}/links/#{url}")
    assert html_response(resp, 200)
    refute resp.resp_body =~ ~s(href="javascript)
    assert resp.resp_body =~ ~s(href="#")
  end

  test "redirect when deleting url", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    url = insert(:url, user: user)
    conn = delete(conn, ~p"/#{user}/links/#{url}")
    assert redirected_to(conn) == ~p"/#{user}/links"
    refute Repo.get(Url, url.id)
  end

  # The reorder/move interactions themselves (drag + arrows) live in
  # VutuvWeb.SectionReorderLive; see section_reorder_live_test.exs and
  # ordering_test.exs. Here we only check what the controller still owns: new
  # links get a position on create, and the owner — not a visitor — gets the
  # embedded reorder tool.
  describe "ordering" do
    test "new links get the next position", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/#{user}/links", url: %{"value" => "one.example", "description" => "one"})
      post(conn, ~p"/#{user}/links", url: %{"value" => "two.example", "description" => "two"})

      [first, second] = Repo.all(Url.ordered(Ecto.assoc(user, :urls)))
      assert first.value == "http://one.example"
      assert first.position == 1
      assert second.value == "http://two.example"
      assert second.position == 2
    end

    test "the index lists links in their chosen order", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:url, user: user, description: "Bravo", position: 2)
      insert(:url, user: user, description: "Alpha", position: 1)

      html = conn |> get(~p"/#{user}/links") |> html_response(200)

      {alpha, _} = :binary.match(html, "Alpha")
      {bravo, _} = :binary.match(html, "Bravo")
      assert alpha < bravo, "expected the position-1 link to render before position-2"
    end

    test "the owner sees the reorder tool, a visitor does not", %{conn: conn} do
      {owner_conn, user} = create_and_login_user(conn)
      insert_list(2, :url, user: user)

      owner_html = owner_conn |> get(~p"/#{user}/links") |> html_response(200)
      assert owner_html =~ ~s(phx-hook="Reorder")

      visitor_html = build_conn() |> get(~p"/#{user}/links") |> html_response(200)
      refute visitor_html =~ ~s(phx-hook="Reorder")
    end
  end

  defp create_url(conn, url_value) do
    {conn, user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/#{user}/links", url: %{"value" => url_value, "description" => "test"})

    {conn, user}
  end

  defp set_url(conn, url_value) do
    {conn, user} = create_and_login_user(conn)
    url = insert(:url, user: user)

    conn =
      put(conn, ~p"/#{user}/links/#{url}", url: %{"value" => url_value, "description" => "test"})

    {conn, user, url}
  end
end
