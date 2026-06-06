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

  test "return 400 when creating invalid url", %{conn: conn} do
    {conn, user} = create_url(conn, "invalid_url")
    assert html_response(conn, 400) =~ ~p"/#{user}/links"
    refute Repo.get_by(Url, value: "invalid_url", user_id: user.id)
  end

  test "return 400 when creating empty url", %{conn: conn} do
    {conn, user} = create_url(conn, "")
    assert html_response(conn, 400) =~ ~p"/#{user}/links"
  end

  test "redirect when setting valid url", %{conn: conn} do
    {conn, user, url} = set_url(conn, "example.org")
    assert redirected_to(conn) == ~p"/#{user}/links/#{url}"
    assert Repo.get(Url, url.id).value == "http://example.org"
  end

  test "return 400 when setting invalid url", %{conn: conn} do
    {conn, user, url} = set_url(conn, "invalid_url")
    assert html_response(conn, 400) =~ ~p"/#{user}/links/#{url}"
    refute Repo.get(Url, url.id).value == "invalid_url"
  end

  test "return 400 when setting empty url", %{conn: conn} do
    {conn, user, url} = set_url(conn, "")
    assert html_response(conn, 400) =~ ~p"/#{user}/links/#{url}"
  end

  test "redirect when deleting url", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    url = insert(:url, user: user)
    conn = delete(conn, ~p"/#{user}/links/#{url}")
    assert redirected_to(conn) == ~p"/#{user}/links"
    refute Repo.get(Url, url.id)
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
      put(conn, ~p"/#{user}/links/#{url}",
        url: %{"value" => url_value, "description" => "test"}
      )

    {conn, user, url}
  end
end
