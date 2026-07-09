defmodule VutuvWeb.LoginCodeControllerTest do
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.LoginCodes

  # The one-time code list ("Kennwortliste", issue #912): view, (re)generate
  # and delete under /settings/login_codes. Owner-only, login-required.

  test "the page requires a login", %{conn: conn} do
    assert conn |> get(~p"/settings/login_codes") |> redirected_to() == "/"
  end

  describe "for a logged-in member" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, %{conn: conn, user: user}}
    end

    test "starts empty with a generate button", %{conn: conn} do
      html = conn |> recycle() |> get(~p"/settings/login_codes") |> html_response(200)

      assert html =~ "generate-codes-form"
      refute html =~ "login-code-list"
    end

    test "generating shows the ten codes, regenerating replaces them", %{
      conn: conn,
      user: user
    } do
      conn = conn |> recycle() |> post(~p"/settings/login_codes")
      assert redirected_to(conn) == ~p"/settings/login_codes"

      codes = LoginCodes.list_codes(user)
      assert length(codes) == 10

      html = conn |> recycle() |> get(~p"/settings/login_codes") |> html_response(200)
      for %{code: code} <- codes, do: assert(html =~ code)

      # The security page's row reports the list.
      security = conn |> recycle() |> get(~p"/settings/security") |> html_response(200)
      assert security =~ "10 of 10 codes unused."

      # Regenerating replaces every code.
      [%{code: old} | _] = codes
      conn |> recycle() |> post(~p"/settings/login_codes")
      new_codes = LoginCodes.list_codes(user)
      assert length(new_codes) == 10
      refute old in Enum.map(new_codes, & &1.code)
    end

    test "a used code renders struck through", %{conn: conn, user: user} do
      [%{code: code} | _] = LoginCodes.generate_list_codes(user)
      assert :ok = LoginCodes.redeem_login_code(user, code)

      html = conn |> recycle() |> get(~p"/settings/login_codes") |> html_response(200)
      assert html =~ "line-through"
    end

    test "deleting removes the list", %{conn: conn, user: user} do
      LoginCodes.generate_list_codes(user)

      conn = conn |> recycle() |> delete(~p"/settings/login_codes")

      assert redirected_to(conn) == ~p"/settings/security"
      refute LoginCodes.list_codes?(user)
    end
  end
end
