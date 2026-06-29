defmodule VutuvWeb.Plug.NewsletterClickTest do
  @moduledoc """
  The `:browser`-pipeline plug behind newsletter click tracking: a GET carrying a
  valid `?nlt=` token records the click and redirects to the clean URL; a missing
  or invalid token leaves the request alone.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Newsletters
  alias Vutuv.Newsletters.NewsletterClick
  alias Vutuv.Repo
  alias VutuvWeb.NewsletterToken

  setup do
    admin = insert(:activated_user, admin?: true)
    user = insert(:activated_user)
    insert(:email, user: user, value: "click@example.com")

    {:ok, newsletter} =
      Newsletters.create_newsletter(%{"subject" => "S", "body" => "B"}, admin)

    %{newsletter: newsletter, user: user}
  end

  defp clicks, do: Repo.all(NewsletterClick)

  test "records the click and redirects to the clean URL", %{
    conn: conn,
    newsletter: newsletter,
    user: user
  } do
    token = NewsletterToken.sign(newsletter, user)
    conn = get(conn, ~p"/?#{[nlt: token]}")

    assert redirected_to(conn) == "/"

    assert [click] = clicks()
    assert click.newsletter_id == newsletter.id
    assert click.user_id == user.id
    assert click.url == "/"
  end

  test "preserves other query parameters when stripping the token", %{
    conn: conn,
    newsletter: newsletter,
    user: user
  } do
    token = NewsletterToken.sign(newsletter, user)
    conn = get(conn, ~p"/?#{[nlt: token, foo: "bar"]}")

    assert redirected_to(conn) == "/?foo=bar"
    assert [%{url: "/"}] = clicks()
  end

  test "an invalid token strips and redirects but records nothing", %{conn: conn} do
    conn = get(conn, ~p"/?#{[nlt: "bogus"]}")

    assert redirected_to(conn) == "/"
    assert clicks() == []
  end

  test "a normal request without the token is untouched", %{conn: conn} do
    assert html_response(get(conn, ~p"/"), 200)
    assert clicks() == []
  end
end
