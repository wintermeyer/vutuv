defmodule VutuvWeb.UrlParameter500sTest do
  @moduledoc """
  Two public URLs that answered a crafted query string with a 500.

  Neither is a data leak; both are a stranger being able to put an error page
  where a listing belongs, from a URL they can type. They are here together
  because they are the same mistake: a parameter whose shape was assumed rather
  than checked, and a guard that looked total and was not.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Pages

  describe "?page= on an offset-paginated listing" do
    # `?page[]=1` arrives as a LIST. `max/2` does not raise on one — Elixir's
    # term ordering puts a list above an integer, so `max(["1"], 1)` answered
    # `["1"]` and the `(page - 1)` that follows raised ArithmeticError.
    test "a non-integer page collapses to the first page" do
      assert Pages.effective_page(%{"page" => ["1"]}, 500) == 1
      assert Pages.effective_page(%{"page" => %{"a" => "1"}}, 500) == 1
      assert Pages.effective_page(%{"page" => nil}, 500) == 1
      assert Pages.effective_page(%{"page" => "not-a-number"}, 500) == 1
    end

    test "an ordinary page still works" do
      assert Pages.effective_page(%{"page" => "2"}, 500) == 2
      assert Pages.effective_page(%{"page" => 2}, 500) == 2
      # Past the data, back to the first page — the pre-existing rule.
      assert Pages.effective_page(%{"page" => "99"}, 10) == 1
    end

    test "the member directory survives it end to end", %{conn: conn} do
      assert conn |> get("/system/members?page[]=1") |> response(200)
    end
  end

  describe "a sitemap chunk number" do
    # Past 2^63 Postgres never sees a query: Postgrex raises
    # DBConnection.EncodeError on the OFFSET parameter, so the action's promised
    # 404 was a 500.
    test "an absurd chunk number is a 404, not a 500", %{conn: conn} do
      assert conn |> get("/sitemaps/users-99999999999999999999.xml") |> response(404)
    end

    test "a chunk beyond the data is still a 404", %{conn: conn} do
      assert conn |> get("/sitemaps/users-9999.xml") |> response(404)
    end

    test "an unknown type is still a 404", %{conn: conn} do
      assert conn |> get("/sitemaps/nonsense-1.xml") |> response(404)
    end
  end
end
