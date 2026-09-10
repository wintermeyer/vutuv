defmodule VutuvWeb.MediaKitReportReachTest do
  @moduledoc """
  Whether a rights holder can **reach** the Report control on the Media Kit
  (issue #2139) — not who is offered one, which is `PressKitReportTest`.

  Two defects, both measured in a browser before the fix and both invisible to
  a markup assertion on their own.

  In the **lightbox** the picture was capped at `calc(100vh - 9rem)`, a fixed
  guess at how much room the caption block below it would want. A caption is
  not a fixed height, so the stage grew past the window and, with nothing
  scrolling, the footer carrying the Report line went under the bottom edge: at
  1280×900 with a portrait photo and a 392-character caption the link's bottom
  edge measured 968 px, at 1440×720 it measured 788 px, and an uncaptioned
  photo fitted either way. The picture has to **yield** to the caption instead,
  and a caption long enough to fill the screen on its own has to scroll without
  taking the footer with it — a press caption may be 10,000 characters.

  On the **section page** the Report link was a 15 px run of text beside 40 px
  download buttons on the same card, which is not a target a thumb hits.

  What is pinned here is the shape that makes both true: the rules the stage is
  laid out by, the order and nesting of the overlay the script builds, and the
  classes the rendered link carries. What only a browser can prove is the
  measurement itself — that the link's bottom edge is inside the window at
  1280×900, 1440×720 and 390 px wide with a caption of any length, and that the
  picture still takes the room the caption leaves.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.ImageHelpers, only: [put_press_picture: 2]

  @js Path.expand("../../assets/js/lightbox.js", __DIR__)
  @css Path.expand("../../assets/css/components.css", __DIR__)

  defp js, do: File.read!(@js)
  defp css, do: File.read!(@css)

  # Every declaration written for a selector, joined — the shape
  # `line_clamp_css_test`'s `declarations/1` uses, and for its reason: a rule
  # for the same selector may be repeated (this file's `@media (width < 40rem)`
  # block is exactly where a mobile regression would land), so reading only the
  # first match would let a later override pass unseen. The selector must start
  # a line or be indented, never merely appear inside a longer one.
  defp rule(selector) do
    case Regex.scan(~r/(?:^|\n)[ \t]*#{Regex.escape(selector)}\s*\{([^}]*)\}/, css()) do
      [] -> flunk("no `#{selector}` rule in components.css")
      matches -> matches |> Enum.map_join("\n", fn [_, body] -> body end)
    end
  end

  describe "the lightbox stage" do
    test "the picture yields to the caption instead of reserving a fixed strip for it" do
      refute css() =~ ~r/\.lightbox__image\s*\{[^}]*max-height:\s*calc\(100vh/,
             "a fixed reservation cannot know how tall a caption is — that is the defect"

      frame = rule(".lightbox__frame")

      assert frame =~ "min-height: 0",
             "a flex item's automatic minimum is its content, so without this the " <>
               "picture never gives a single pixel back to the caption"

      assert rule(".lightbox__image") =~ "max-height: 100%",
             "the picture is bounded by the room the frame was left, not by the window"
    end

    test "an endless caption scrolls on its own and leaves the footer standing" do
      assert rule(".lightbox__text") =~ "overflow-y: auto"

      assert rule(".lightbox__meta") =~ ~r/max-height:\s*\d/,
             "the caption block needs a ceiling or it eats the picture"

      assert rule(".lightbox__footer") =~ "flex: none",
             "the footer must not shrink away with the text it sits under"

      refute rule(".lightbox__meta") =~ ~r/max-height:[^;]*v[hw]/,
             "the ceiling is a share of the stage, not a slice of the window: the stage is " <>
               "the window less the overlay's padding, so a `vh` reads wider on a phone than " <>
               "it says — widest where the room is scarcest"
    end

    test "the stage centres safely, because zoomed it is the scroller" do
      # Both axes, and the reason is one: content centred in a scroll container
      # overflows on BOTH sides, and the leading half then sits outside the
      # scrollable region. `align-items` has guarded this since the zoom
      # shipped; `justify-content` arrived with #2139 and needs the same guard.
      assert rule(".lightbox__stage") =~ "justify-content: safe center",
             "a bare `center` here strands the top of a zoomed picture — no scrolling reaches it"

      # Horizontally it is the FRAME that holds the picture now, the stage's
      # `align-items` only placing the caption block beside it — so pin the
      # declaration that does the work, not the one the comments grew up on.
      assert rule(".lightbox.is-zoomed .lightbox__frame") =~ "justify-content: flex-start",
             "centred, a picture wider than the stage overflows both ways and its left half " <>
               "can never be scrolled to"
    end

    test "zoomed, the caption block stops giving way" do
      # The frame is then the picture's own size and larger than the stage, so
      # all the negative free space lands on whatever may still shrink —
      # measured: caption and credit at height 0, the footer alone surviving.
      block = rule(".lightbox.is-zoomed .lightbox__meta")

      assert block =~ "flex: none"
      assert block =~ "max-height: none"
    end
  end

  describe "the phone's bottom row" do
    test "the stage clears the arrows by their own height, not by a constant" do
      # The arrows move to the bottom corners under 40rem. An absolute offset is
      # measured from the padding box, so the overlay's padding cannot move them
      # — it can only leave room. A literal there is right for a device that
      # reports no bottom inset and wrong for every phone that does (measured:
      # a 34px home indicator turned 8px of clearance into a 10px overlap).
      # `rule/1` joins every `.lightbox { … }` in the file, so this reads the
      # base rule and the phone override together.
      overlay = rule(".lightbox")

      assert overlay =~ "--lb-nav-size:", "the arrows' size has to be readable, not retyped"
      assert overlay =~ "--lb-nav-inset:"

      assert overlay =~ ~r/padding-bottom:[^;]*--lb-nav-inset/,
             "the padding must be derived from the same inset the arrows sit on"

      refute overlay =~ ~r/padding-bottom:\s*[\d.]+rem\s*;/,
             "a constant here cannot know what the device reserves at that edge"

      assert rule(".lightbox__nav") =~ "var(--lb-nav-size)",
             "the arrows have to read the size the padding is computed from"
    end
  end

  describe "the overlay the script builds" do
    test "the picture sits in the frame the stage sizes" do
      assert js() =~ ~r/lightbox__frame[^`]*lightbox__image/s,
             "the frame has to wrap the picture, or the CSS above has nothing to size"
    end

    test "the Report line sits outside the block that scrolls" do
      markup = js()

      [_, after_text] = String.split(markup, ~s(class="lightbox__text"), parts: 2)
      [text_block, rest] = String.split(after_text, "</div>", parts: 2)

      refute text_block =~ "data-lb-report",
             "inside the scroller the Report line scrolls out of sight again"

      assert rest =~ "data-lb-report"
      assert rest =~ "data-lb-download"
    end

    test "every link in the footer is a finger-sized target" do
      assert rule(".lightbox__footer a") =~ ~r/min-height:\s*2\.5rem/,
             "40px, the size every other control on these pages is"
    end
  end

  describe "the section page" do
    test "the Report link is a 40px target, not a run of text" do
      owner = insert_activated_user(username: "presse.reichweite")
      put_press_picture(owner, caption: "Am Schreibtisch, kurz vor der Ansprache.")

      html = build_conn() |> get(~p"/#{owner}/media-kit") |> html_response(200)

      # Whole classes out of a parsed element, never a substring of the raw tag:
      # `String.contains?` would take `sm:min-h-10` or `min-h-100` for the class
      # asked for, which is the false pass `ClassAvailability.used_in?/2` carries
      # its own scar tissue about.
      assert [link] = elements(html, "a[data-press-report]")
      classes = link |> attribute("class") |> String.split()

      # `ml-2` is part of the same change, not decoration: the separator that
      # used to precede the link went, because an atomic inline box drops to a
      # line of its own on a phone and left the dot dangling above it.
      for class <- ~w(inline-flex min-h-10 items-center ml-2) do
        assert class in classes,
               "the Report anchor needs `#{class}`; it measured 15 px tall beside a 40 px " <>
                 "download button on the same card. It carries: #{Enum.join(classes, " ")}"
      end
    end
  end
end
