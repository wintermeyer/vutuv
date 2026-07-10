defmodule VutuvWeb.Admin.PrefControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Prefs

  describe "access" do
    test "a logged-in non-admin is refused", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, ~p"/admin/preferences")
      assert html_response(conn, 403)
    end
  end

  describe "index" do
    setup [:admin_conn]

    test "renders every registry pref with its effective default", %{conn: conn} do
      conn = get(conn, ~p"/admin/preferences")
      html = html_response(conn, 200)

      assert html =~ "Preference defaults"

      for pref <- Prefs.registry() do
        assert html =~ ~s(id="pref_#{pref.key}"),
               "no control for #{pref.key} on the admin defaults page"
      end

      # The two group forms post back to this page (assert the rendered
      # action=, per the form-URL lesson from v7.34-v7.42).
      assert html =~ ~s(action="/admin/preferences")
    end

    test "shows a stored override in the control", %{conn: conn} do
      {:ok, _} = Prefs.put_defaults(%{"post_lines_desktop" => "12"})

      conn = get(conn, ~p"/admin/preferences")
      html = html_response(conn, 200)

      assert html =~ ~s(id="pref_post_lines_desktop")
      assert html =~ ~s(value="12")
    end
  end

  describe "update" do
    setup [:admin_conn]

    test "stores overrides and lands back on the page", %{conn: conn} do
      conn =
        put(conn, ~p"/admin/preferences",
          prefs: %{
            "post_lines_desktop" => "12",
            "post_lines_mobile" => "8",
            "post_hyphenate_desktop" => "true",
            "post_hyphenate_mobile" => "true"
          }
        )

      assert redirected_to(conn) == ~p"/admin/preferences"

      assert Prefs.list_default_rows() == %{
               post_lines_desktop: "12",
               post_hyphenate_desktop: "true"
             }
    end

    test "setting a value back to the shipped default removes its override", %{conn: conn} do
      {:ok, _} = Prefs.put_defaults(%{"default_map_service" => "apple"})

      conn =
        put(conn, ~p"/admin/preferences",
          prefs: %{
            "map_google?" => "true",
            "map_openstreetmap?" => "true",
            "map_apple?" => "true",
            "default_map_service" => "google"
          }
        )

      assert redirected_to(conn) == ~p"/admin/preferences"
      assert Prefs.list_default_rows() == %{}
    end

    test "an invalid value re-renders with the field marked and stores nothing", %{conn: conn} do
      conn =
        put(conn, ~p"/admin/preferences",
          prefs: %{"post_lines_desktop" => "999", "post_lines_mobile" => "4"}
        )

      html = html_response(conn, 422)
      assert html =~ ~s(id="pref_post_lines_desktop")
      # The submitted raw value is kept on the re-render...
      assert html =~ ~s(value="999")
      # ...and nothing was written.
      assert Prefs.list_default_rows() == %{}
    end
  end

  defp admin_conn(%{conn: conn}) do
    {conn, admin} = create_and_login_admin(conn)
    %{conn: conn, admin: admin}
  end
end
