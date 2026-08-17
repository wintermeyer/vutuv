defmodule VutuvWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Vutuv.ViewerClock
  alias VutuvWeb.UI

  # The timestamp components read the viewer's date shape and time zone off the
  # process (issue #1502), which the Locale plug sets per request. Each test
  # says what it is rendering for, so nothing depends on the installation
  # defaults; `own_zone?` is the flag that decides whether the server's text is
  # final or the browser still rewrites it.
  defp put_viewer(region, zone \\ "Europe/Berlin", own_zone? \\ true) do
    ViewerClock.put(region, zone, own_zone?)
  end

  # Noon UTC on yesterday's calendar day for the viewer clock currently set, as
  # a NaiveDateTime (post_time reads a naive value as UTC). Noon keeps the day
  # unambiguous - far from either midnight - so the "yesterday" bucket is stable
  # whenever tests run.
  defp yesterday_noon do
    ViewerClock.today()
    |> Date.add(-1)
    |> DateTime.new!(~T[12:00:00], "Etc/UTC")
    |> DateTime.to_naive()
  end

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
    # Rendered server-side in the reader's own zone and date shape, so it must
    # not carry the client-side data-localtime marker the JS localizer rewrites
    # — only the server knows which calendar day "today" is for this reader.
    test "a post from today shows only the time, with 'Uhr' in German" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      put_viewer("DE")
      html = render_component(&UI.post_time/1, at: NaiveDateTime.utc_now())

      # Visible text is just the time; the full date lives only in the hover title.
      assert html =~ ~r/>\d{2}:\d{2} Uhr</
      refute html =~ ~r/>\d{2}\.\d{2}\.\d{2}/
      refute html =~ "data-localtime"
      assert html =~ "datetime="
    end

    test "an older post shows the full short date and time in German" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      put_viewer("DE")
      # 2020-01-15 10:00 UTC is winter (CET, UTC+1) -> 11:00 Berlin.
      html = render_component(&UI.post_time/1, at: ~N[2020-01-15 10:00:00])

      assert html =~ "15.01.20, 11:00"
      refute html =~ "Uhr"
    end

    test "a post from yesterday says 'Gestern' with the time and no numeric date in German" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      put_viewer("DE")
      # Yesterday in Berlin, at a time far from midnight so the Berlin day is
      # unambiguous. post_time treats a NaiveDateTime as UTC.
      at = %{yesterday_noon() | second: 0}
      html = render_component(&UI.post_time/1, at: at)

      assert html =~ ~r/>Gestern, \d{2}:\d{2} Uhr</
      # No dotted numeric date in the visible label (it stays in the hover title).
      refute html =~ ~r/>Gestern, \d{2}\.\d{2}\.\d{2}/
    end

    test "a post from yesterday says 'Yesterday' under a non-German locale" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      put_viewer("US")
      at = %{yesterday_noon() | second: 0}
      html = render_component(&UI.post_time/1, at: at)

      assert html =~ ~r/>Yesterday, \d{1,2}:\d{2}\s?(AM|PM)</
    end

    test "today shows a bare time (no 'Uhr') under a non-German locale" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      put_viewer("US")
      html = render_component(&UI.post_time/1, at: NaiveDateTime.utc_now())

      assert html =~ ~r/\d{1,2}:\d{2}\s?(AM|PM)/
      refute html =~ "Uhr"
    end

    test "an older post shows the full date in the reader's own region" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      put_viewer("US")

      assert render_component(&UI.post_time/1, at: ~N[2020-01-15 10:00:00]) =~ "1/15/20, 11:00 AM"
    end

    # The two axes are independent, which is the whole point of issue #1502: the
    # language picks the words, the region picks the digits and the clock.
    test "language and date region are independent" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      put_viewer("US")
      html = render_component(&UI.post_time/1, at: ~N[2020-01-15 10:00:00])

      assert html =~ "1/15/20, 11:00 AM"

      Gettext.put_locale(VutuvWeb.Gettext, "en")
      put_viewer("DE")
      html = render_component(&UI.post_time/1, at: %{yesterday_noon() | second: 0})

      assert html =~ ~r/>Yesterday, \d{2}:\d{2}</
      refute html =~ "AM"
    end

    # "Uhr" is a 24-hour-clock word. A German reader on the US shape must not be
    # handed "11:00 AM Uhr".
    test "the German 'Uhr' suffix is dropped on a 12-hour region" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      put_viewer("US")

      refute render_component(&UI.post_time/1, at: NaiveDateTime.utc_now()) =~ "Uhr"
    end

    test "the stamp is written in the reader's own time zone" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")
      # 2020-01-15 10:00 UTC is 11:00 in Berlin, 04:00 in Chicago (CST), 19:00 in Tokyo.
      put_viewer("ISO", "America/Chicago")
      assert render_component(&UI.post_time/1, at: ~N[2020-01-15 10:00:00]) =~ "2020-01-15, 04:00"

      put_viewer("ISO", "Asia/Tokyo")
      assert render_component(&UI.post_time/1, at: ~N[2020-01-15 10:00:00]) =~ "2020-01-15, 19:00"
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

    test "both ends stay reachable from the middle of a long list" do
      # 10,000 rows -> 40 pages; from page 20 the window is 15..25, so without
      # the end jumps neither page 1 nor page 40 could be reached in one click.
      html = render_component(&UI.pager/1, params: %{"page" => "20"}, total: 10_000)

      assert html =~ ~s(page=1")
      assert html =~ ~s(page=40")
      assert html =~ "…"
    end

    test "no ellipsis where the window already touches the end" do
      # 600 rows -> 12 pages; from page 6 the window is 1..11, so only the
      # last page is missing and there is nothing to elide before it.
      html = render_component(&UI.pager/1, params: %{"page" => "6"}, total: 3000)

      assert html =~ ~s(page=12")
      refute html =~ "…"
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

    test "an explicit format wins over the viewer's date region" do
      at = ~N[2026-06-20 09:30:00]
      put_viewer("US", "Etc/UTC")

      assert render_component(&UI.local_time/1, at: at, format: "%Y-%m-%d %H:%M") =~
               "2026-06-20 09:30"

      assert render_component(&UI.local_time/1, at: at, format: "%d.%m.%Y %H:%M") =~
               "20.06.2026 09:30"
    end

    test "without a format the text follows the viewer's own region and zone" do
      at = ~N[2026-06-20 09:30:00]

      put_viewer("DE", "Europe/Berlin")
      assert render_component(&UI.local_time/1, at: at) =~ "20.06.2026 11:30"

      put_viewer("US", "America/New_York")
      assert render_component(&UI.local_time/1, at: at) =~ "6/20/2026 5:30 AM"
    end

    # The browser keeps the last word only while nothing on the server knows the
    # reader's zone. Once a member has picked one, their setting must beat the
    # machine they happen to be reading on, so the client rewrite is called off.
    test "a member's own zone makes the server text final and drops the JS rewrite" do
      at = ~N[2026-06-20 09:30:00]

      put_viewer("DE", "Europe/Berlin", false)
      inherited = render_component(&UI.local_time/1, at: at, id: "t")
      assert inherited =~ "data-localtime"
      assert inherited =~ ~s(phx-hook="LocalTime")
      # The fallback text is the instant in UTC (09:30, not Berlin's 11:30) —
      # the browser is about to overwrite it, and the ISO `title` keeps the
      # unambiguous stamp either way.
      assert inherited =~ "20.06.2026 09:30"

      put_viewer("DE", "Europe/Berlin")
      own = render_component(&UI.local_time/1, at: at, id: "t")
      refute own =~ "data-localtime"
      refute own =~ "phx-hook"
      assert own =~ "20.06.2026 11:30"
    end
  end
end
