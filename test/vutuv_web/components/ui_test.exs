defmodule VutuvWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias VutuvWeb.UI

  # Page size is the compile-time `max_page_items` (250 in config.exs), so
  # totals below are chosen relative to that: 600 rows -> 3 pages, etc.
  describe "pager/1" do
    test "renders nothing when everything fits on one page" do
      refute render_component(&UI.pager/1, params: %{}, total: 10) =~ "<nav"
    end

    test "links the other pages and highlights the current one" do
      html = render_component(&UI.pager/1, params: %{"page" => "2"}, total: 600)

      assert html =~ ~s(page=1")
      assert html =~ ~s(page=3")
      # The current page is a highlighted marker, not a link.
      refute html =~ ~s(page=2")
      assert html =~ ~s(aria-current="page")
    end

    test "windows long page ranges with ellipses" do
      # 5000 rows -> 20 pages; current page 10 windows to 5..15.
      html = render_component(&UI.pager/1, params: %{"page" => "10"}, total: 5000)

      assert html =~ ~s(page=5")
      assert html =~ ~s(page=15")
      refute html =~ ~s(page=4")
      refute html =~ ~s(page=16")
      assert html =~ "…"
    end

    test "a garbage page param falls back to page 1" do
      html = render_component(&UI.pager/1, params: %{"page" => "banana"}, total: 600)

      assert html =~ ~s(aria-current="page")
      # Page 1 is current, so it is not a link.
      refute html =~ ~s(page=1")
    end

    test "an out-of-range page highlights page 1, matching the shown rows" do
      # Pages.paginate falls back to offset 0 for impossible pages; the pager
      # must highlight the page whose rows are actually displayed.
      html = render_component(&UI.pager/1, params: %{"page" => "999"}, total: 600)

      refute html =~ ~s(page=1")
      assert html =~ ~s(page=2")
    end
  end
end
