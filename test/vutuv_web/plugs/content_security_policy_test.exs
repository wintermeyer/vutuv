defmodule VutuvWeb.Plug.ContentSecurityPolicyTest do
  @moduledoc """
  Every browser-pipeline response carries a Content-Security-Policy. With
  user-supplied Markdown rendered all over the site, CSP is the second line
  of defense should an XSS slip past the sanitizer: no external or inline
  scripts can run, forms cannot be re-targeted off-site.
  """
  use VutuvWeb.ConnCase

  defp csp(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [value] -> value
      [] -> nil
    end
  end

  test "pages carry the policy: self-only scripts, no objects", %{conn: conn} do
    policy = conn |> get(~p"/") |> csp()

    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "base-uri 'self'"
    assert policy =~ "form-action 'self'"
    # The CSS data-URI icons in components.css load as images.
    assert policy =~ "img-src 'self' data:"
  end

  test "connect-src names the websocket origin so LiveView can join", %{conn: conn} do
    policy = conn |> get(~p"/") |> csp()

    # ConnTest conns are http://www.example.com → ws://www.example.com.
    assert policy =~ "connect-src 'self' ws://www.example.com"
  end

  test "the unsubscribe pipeline carries it too", %{conn: conn} do
    user = insert(:activated_user)
    token = VutuvWeb.UnsubscribeToken.sign(user)

    policy = conn |> get(~p"/unsubscribe/#{token}") |> csp()
    assert policy =~ "default-src 'self'"
  end
end
