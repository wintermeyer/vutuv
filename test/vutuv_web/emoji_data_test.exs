defmodule VutuvWeb.EmojiDataTest do
  @moduledoc """
  The composer's emoji dataset (`assets/js/emoji_data.js`, issue #1197) is
  client-side, so `mix test` cannot exercise the picker itself — but the data is
  a flat table, and its invariants are exactly the ones a browser would not
  complain about:

    * a shortcode outside `[a-z0-9_+-]` can never be typed through, because
      `SHORTCODE_AT_CARET` would not match it. The picker would still offer the
      emoji, so nothing looks broken; `:Tada:` simply does nothing, forever.
    * a duplicated emoji shows up twice in one group's grid.
    * a duplicated shortcode is a silently-ignored second definition (the map is
      first-writer-wins), so the alias points at the wrong picture.

  Every entry is `[character, shortcodes, english, german]`; parsing that with a
  regex is enough, and it keeps the dataset a plain list a human can extend with
  one line.
  """
  use ExUnit.Case, async: true

  @path "assets/js/emoji_data.js"

  @entry ~r/^\s{4}\["(?<char>[^"]+)", "(?<codes>[^"]*)", "(?<en>[^"]*)", "(?<de>[^"]*)"\],$/

  defp entries do
    @path
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.named_captures(@entry, line) do
        nil -> []
        captures -> [captures]
      end
    end)
  end

  test "the dataset parses and is big enough to be worth a picker" do
    entries = entries()

    # A regex that stops matching (someone reformats the file) would turn every
    # assertion below into a vacuous pass over an empty list.
    assert length(entries) > 300
  end

  test "every shortcode is typeable (matches SHORTCODE_AT_CARET)" do
    # Kept in step with the pattern in emoji_data.js by hand — it is the one
    # place the two sides have to agree, and it has not changed since.
    typeable = ~r/^[a-z0-9_+-]{1,32}$/

    for entry <- entries(), code <- String.split(entry["codes"], " ", trim: true) do
      assert Regex.match?(typeable, code),
             "shortcode #{inspect(code)} can never be typed through (#{entry["char"]})"
    end
  end

  test "no emoji and no shortcode is defined twice" do
    entries = entries()

    chars = Enum.map(entries, & &1["char"])
    assert chars -- Enum.uniq(chars) == []

    codes = Enum.flat_map(entries, &String.split(&1["codes"], " ", trim: true))
    assert codes -- Enum.uniq(codes) == []
  end

  test "every emoji carries a canonical shortcode and German search words" do
    for entry <- entries() do
      assert String.split(entry["codes"], " ", trim: true) != [],
             "#{entry["char"]} has no shortcode, so it cannot be searched or typed"

      # German is not optional: vutuv is a German site, so a member typing
      # "Herz" has to find the heart. English comes free with the shortcode.
      assert String.trim(entry["de"]) != "",
             "#{entry["char"]} has no German search words"
    end
  end
end
