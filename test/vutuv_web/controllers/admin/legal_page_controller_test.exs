defmodule VutuvWeb.Admin.LegalPageControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Legal

  describe "access control" do
    test "a logged-in non-admin gets a 403", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = get(conn, ~p"/admin/legal")

      assert conn.status == 403
    end

    test "an anonymous visitor is redirected away", %{conn: conn} do
      conn = get(conn, ~p"/admin/legal")

      assert redirected_to(conn)
    end
  end

  describe "index" do
    setup :login_admin

    test "lists the three legal pages with their state", %{conn: conn} do
      {:ok, _page} = Legal.upsert_page("impressum", %{body: "**Acme GmbH**"})

      body = conn |> get(~p"/admin/legal") |> html_response(200)

      assert body =~ "Impressum"
      assert body =~ "Datenschutzerklärung"
      assert body =~ "Nutzungsbedingungen"
      # One page is written, two still show as missing.
      assert body =~ ~p"/admin/legal/impressum/edit"
      assert body =~ ~p"/admin/legal/nutzungsbedingungen/edit"
    end
  end

  describe "edit" do
    setup :login_admin

    test "renders the editor form, pre-filled with the stored body", %{conn: conn} do
      {:ok, _page} = Legal.upsert_page("impressum", %{body: "**Acme GmbH**"})

      body = conn |> get(~p"/admin/legal/impressum/edit") |> html_response(200)

      assert body =~ "Acme GmbH"
      assert body =~ ~s(name="legal_page[body]")
    end

    test "renders an empty editor for a page not written yet", %{conn: conn} do
      body = conn |> get(~p"/admin/legal/impressum/edit") |> html_response(200)

      assert body =~ ~s(name="legal_page[body]")
    end

    test "404s on an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/admin/legal/robots/edit")

      assert conn.status == 404
    end
  end

  describe "update" do
    setup :login_admin

    test "stores the page and redirects to the listing", %{conn: conn} do
      conn =
        put(conn, ~p"/admin/legal/impressum", %{
          "legal_page" => %{"body" => "**Acme GmbH**\nMusterweg 1"}
        })

      assert redirected_to(conn) == ~p"/admin/legal"
      assert Legal.get_page("impressum").body =~ "Acme GmbH"
    end

    test "re-renders the form on a validation error", %{conn: conn} do
      conn = put(conn, ~p"/admin/legal/impressum", %{"legal_page" => %{"body" => ""}})

      assert html_response(conn, 200) =~ ~s(name="legal_page[body]")
      assert Legal.get_page("impressum") == nil
    end

    test "404s on an unknown slug", %{conn: conn} do
      conn = put(conn, ~p"/admin/legal/robots", %{"legal_page" => %{"body" => "x"}})

      assert conn.status == 404
    end
  end

  defp login_admin(%{conn: conn}) do
    {conn, admin} = create_and_login_admin(conn)
    {:ok, conn: conn, admin: admin}
  end
end
