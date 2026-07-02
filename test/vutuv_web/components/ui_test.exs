defmodule VutuvWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
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

  describe "post_time/1" do
    # A post made today shows only the time; older posts keep the full date.
    # Rendered server-side in Europe/Berlin time (Vutuv.BerlinTime), so it must
    # not carry the client-side data-localtime marker the JS localizer rewrites.
    test "a post from today shows only the time, with 'Uhr' in German" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      html = render_component(&UI.post_time/1, at: NaiveDateTime.utc_now())

      # Visible text is just the time; the full date lives only in the hover title.
      assert html =~ ~r/>\d{2}:\d{2} Uhr</
      refute html =~ ~r/>\d{2}\.\d{2}\.\d{2}/
      refute html =~ "data-localtime"
      assert html =~ "datetime="
    end

    test "an older post shows the full short date and time in German" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      # 2020-01-15 10:00 UTC is winter (CET, UTC+1) -> 11:00 Berlin.
      html = render_component(&UI.post_time/1, at: ~N[2020-01-15 10:00:00])

      assert html =~ "15.01.20, 11:00"
      refute html =~ "Uhr"
    end

    test "today shows a bare time (no 'Uhr') under a non-German locale" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      html = render_component(&UI.post_time/1, at: NaiveDateTime.utc_now())

      assert html =~ ~r/\d{1,2}:\d{2}\s?(AM|PM)/
      refute html =~ "Uhr"
    end

    test "an older post shows the locale-appropriate full date in English" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      html = render_component(&UI.post_time/1, at: ~N[2020-01-15 10:00:00])

      assert html =~ "1/15/20, 11:00 AM"
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

  describe "row_actions/1 alignment" do
    test "defaults to right-aligned for table-row cells" do
      assigns = %{}
      html = rendered_to_string(~H|<UI.row_actions edit_to="/e" delete_to="/d" />|)

      assert html =~ "justify-end"
      assert html =~ "Edit"
      assert html =~ "Delete"
    end

    test "align={:start} left-aligns the controls (no justify-end)" do
      assigns = %{}
      html = rendered_to_string(~H|<UI.row_actions edit_to="/e" delete_to="/d" align={:start} />|)

      refute html =~ "justify-end"
      assert html =~ "Edit"
    end
  end

  describe "button/1" do
    test "the secondary variant darkens its hover in dark mode" do
      assigns = %{}
      html = rendered_to_string(~H|<UI.button variant="secondary">Go</UI.button>|)

      # Without a dark hover, hovering in dark mode flips bg-slate-800 to the
      # light bg-slate-200 (the regression that prompted this test).
      assert html =~ "dark:bg-slate-800"
      assert html =~ "dark:hover:bg-slate-700"
    end
  end

  describe "name_initials/1" do
    test "builds a display-name string's initials" do
      assert UI.name_initials("Greta Tester") == "GT"
    end

    test "builds a user's initials from first+last only, ignoring the honorific" do
      # Regression: a "Dr." title used to leak into the shell monogram ("DA").
      user = %Vutuv.Accounts.User{
        first_name: "Anna",
        last_name: "Schmidt",
        honorific_prefix: "Dr."
      }

      assert UI.name_initials(user) == "AS"
    end

    test "returns ? when there is nothing to abbreviate" do
      assert UI.name_initials(nil) == "?"
      assert UI.name_initials(%Vutuv.Accounts.User{first_name: nil, last_name: nil}) == "?"
    end
  end

  describe "avatar/1" do
    test "marks the <img> with data-avatar so the JS fallback can bind to it" do
      html = render_component(&UI.avatar/1, src: "/avatars/x/Jane%20Doe_thumb.avif")

      assert html =~ "data-avatar"
      assert html =~ ~s(src="/avatars/x/Jane%20Doe_thumb.avif")
    end

    test "lazy-loads by default so list pages don't eager-fetch every avatar" do
      html = render_component(&UI.avatar/1, src: "/avatars/x/pic_thumb.avif")

      assert html =~ ~s(loading="lazy")
      assert html =~ ~s(decoding="async")
    end

    test "an above-the-fold avatar can opt into eager loading" do
      html = render_component(&UI.avatar/1, src: "/avatars/x/pic_thumb.avif", loading: "eager")

      assert html =~ ~s(loading="eager")
    end

    test "falls back to the user's initials when they have no picture" do
      html =
        render_component(&UI.avatar/1,
          user: %Vutuv.Accounts.User{avatar: nil, first_name: "Greta", last_name: "Tester"}
        )

      # An initials tile, not the anonymous placeholder image: it matches the
      # shell's top-bar avatar and tells people apart in lists.
      assert html =~ "data-avatar"
      assert html =~ ">GT<"
      refute html =~ "<img"
    end

    test "a nameless user without a picture gets the ? tile" do
      html = render_component(&UI.avatar/1, user: %Vutuv.Accounts.User{avatar: nil})

      assert html =~ "data-avatar"
      assert html =~ ">?<"
    end

    test "renders the neutral SVG image when given neither user nor src" do
      html = render_component(&UI.avatar/1, [])

      assert html =~ "data-avatar"
      assert html =~ "data:image/svg+xml"
    end

    test "wraps the avatar in a presence shell keyed by the user id when asked" do
      user = %Vutuv.Accounts.User{
        id: "0190abc",
        avatar: nil,
        first_name: "Greta",
        last_name: "Tester"
      }

      html = render_component(&UI.avatar/1, user: user, presence: true)

      # The hook toggles the dot off this wrapper by id; the dot starts hidden.
      assert html =~ ~s(data-presence-user-id="0190abc")
      assert html =~ "presence-dot"
    end

    test "renders no presence wrapper by default so dot-less avatars are unchanged" do
      user = %Vutuv.Accounts.User{id: "x", avatar: nil, first_name: "A", last_name: "B"}
      html = render_component(&UI.avatar/1, user: user)

      refute html =~ "data-presence-user-id"
      refute html =~ "presence-dot"
    end

    test "presence_id supplies the id when only a src is available" do
      html =
        render_component(&UI.avatar/1,
          src: "/avatars/x/p_thumb.avif",
          presence: true,
          presence_id: "user-7"
        )

      assert html =~ ~s(data-presence-user-id="user-7")
    end

    test "presence is a no-op without any resolvable id" do
      html = render_component(&UI.avatar/1, src: "/avatars/x/p_thumb.avif", presence: true)

      refute html =~ "data-presence-user-id"
    end
  end

  describe "presence_wrap/1" do
    test "wraps content with the dot, keyed by id, when given one" do
      assigns = %{}
      html = rendered_to_string(~H|<UI.presence_wrap id="abc"><span>x</span></UI.presence_wrap>|)

      assert html =~ ~s(data-presence-user-id="abc")
      assert html =~ "presence-dot"
    end

    test "renders content bare when no id (system events keep their glyph)" do
      assigns = %{}

      html =
        rendered_to_string(~H|<UI.presence_wrap><span id="inner">x</span></UI.presence_wrap>|)

      refute html =~ "data-presence-user-id"
      refute html =~ "presence-dot"
      assert html =~ ~s(id="inner")
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

  describe "local_time/1" do
    test "emits an ISO-8601 UTC datetime (T-separated, trailing Z) for a naive stamp" do
      # The bug this component centralizes: a space-separated stamp with no Z is
      # read as LOCAL time by the browser. The datetime attribute must be the
      # unambiguous ISO form so the LocalTime pass converts from UTC.
      at = ~N[2026-06-20 09:30:00]
      html = render_component(&UI.local_time/1, at: at)

      assert html =~ ~s(datetime="2026-06-20T09:30:00Z")
      assert html =~ ~s(title="2026-06-20T09:30:00Z")
      assert html =~ "data-localtime"
    end

    test "renders a UTC DateTime as ISO with its Z offset" do
      {:ok, at, 0} = DateTime.from_iso8601("2026-06-20T09:30:00Z")
      html = render_component(&UI.local_time/1, at: at)

      assert html =~ ~s(datetime="2026-06-20T09:30:00Z")
    end

    test "attaches the LocalTime hook only when an id is given" do
      at = ~N[2026-06-20 09:30:00]

      with_id = render_component(&UI.local_time/1, at: at, id: "post-1-at")
      assert with_id =~ ~s(id="post-1-at")
      assert with_id =~ ~s(phx-hook="LocalTime")

      without_id = render_component(&UI.local_time/1, at: at)
      refute without_id =~ "phx-hook"
    end

    test "the visible body is the server-rendered fallback in the requested format" do
      at = ~N[2026-06-20 09:30:00]

      assert render_component(&UI.local_time/1, at: at) =~ "2026-06-20 09:30"

      assert render_component(&UI.local_time/1, at: at, format: "%d.%m.%Y %H:%M") =~
               "20.06.2026 09:30"
    end
  end
end
