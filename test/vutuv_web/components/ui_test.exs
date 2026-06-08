defmodule VutuvWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias VutuvWeb.UI

  describe "compact_count/1" do
    test "shows numbers up to 999 exactly" do
      assert UI.compact_count(0) == "0"
      assert UI.compact_count(7) == "7"
      assert UI.compact_count(999) == "999"
    end

    test "abbreviates thousands as K, flooring so it never overstates" do
      assert UI.compact_count(1_000) == "1K"
      assert UI.compact_count(1_999) == "1K"
      assert UI.compact_count(80_000) == "80K"
      assert UI.compact_count(999_999) == "999K"
    end

    test "abbreviates millions and billions" do
      assert UI.compact_count(1_000_000) == "1M"
      assert UI.compact_count(5_400_000) == "5M"
      assert UI.compact_count(999_999_999) == "999M"
      assert UI.compact_count(2_000_000_000) == "2B"
    end
  end

  describe "delimited_count/1" do
    test "shows small numbers without a separator" do
      assert UI.delimited_count(0) == "0"
      assert UI.delimited_count(7) == "7"
      assert UI.delimited_count(999) == "999"
    end

    test "groups thousands exactly, never flooring" do
      assert UI.delimited_count(1_000) == "1,000"
      assert UI.delimited_count(60_123) == "60,123"
      assert UI.delimited_count(1_000_000) == "1,000,000"
      assert UI.delimited_count(12_345_678) == "12,345,678"
    end

    test "uses a dot separator under the German locale" do
      # Each ExUnit test runs in its own process, so this locale set is isolated.
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      assert UI.delimited_count(60_123) == "60.123"
    end
  end

  describe "count_badge/1" do
    test "renders nothing for a zero count" do
      assert render_component(&UI.count_badge/1, count: 0) |> String.trim() == ""
    end

    test "shows small counts exactly and compacts large ones" do
      assert render_component(&UI.count_badge/1, count: 999) =~ "999"
      assert render_component(&UI.count_badge/1, count: 1_234) =~ "1K"
      refute render_component(&UI.count_badge/1, count: 1_234) =~ "1234"
    end
  end

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
