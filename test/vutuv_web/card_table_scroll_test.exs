defmodule VutuvWeb.CardTableScrollTest do
  use ExUnit.Case, async: true

  # Cards clip their overflow (`.card { overflow: hidden }` contains the
  # floated legacy icons), so a table wider than the card - the admin
  # moderation queue on a narrow window, long email addresses on a phone -
  # gets its trailing columns and row actions cut off with no way to reach
  # them. Every in-card table therefore sits in a `.card__tablewrap`
  # wrapper (components.css), which turns overflow into horizontal scroll.

  @templates Path.expand("../../lib/vutuv_web/templates", __DIR__)

  test "every in-card table sits in a .card__tablewrap scroll wrapper" do
    for file <- Path.wildcard(Path.join(@templates, "**/*.heex")),
        content = File.read!(file),
        tables = length(Regex.scan(~r/<table[\s>]/, content)),
        tables > 0 do
      wraps = length(Regex.scan(~r/card__tablewrap/, content))

      assert wraps >= tables,
             "#{Path.relative_to_cwd(file)}: #{tables} <table> but only #{wraps} " <>
               "card__tablewrap wrapper(s) - a table wider than the card is " <>
               "clipped by the card's overflow:hidden instead of scrolling"
    end
  end

  test "components.css styles .card__tablewrap as a horizontal scroller" do
    css = File.read!(Path.expand("../../assets/css/components.css", __DIR__))

    assert Regex.match?(~r/\.card__tablewrap\s*\{[^}]*overflow-x\s*:\s*auto/, css)
  end
end
