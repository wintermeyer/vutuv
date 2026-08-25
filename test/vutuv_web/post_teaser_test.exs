defmodule VutuvWeb.PostTeaserTest do
  @moduledoc """
  How a quote is cut into browser-tab frames (issue #1681).

  The frames are the whole feature on that surface: a hidden tab gives us about
  four of them before the browser stops advancing the timer, and each one has
  to be a line somebody can read in the width of a tab. So what is worth
  pinning is that the author leads, that words are not cut in half, that a
  pasted URL cannot swallow the frames after it, and that the cap holds.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.PostTeaser

  defp frames(who, text), do: PostTeaser.title_frames(%{who: who, text: text})

  test "the author leads the first frame and is not repeated" do
    [first | rest] = frames("@quotable", "Frisch geflasht, unter zwei Sekunden")

    assert first =~ "@quotable"
    refute Enum.any?(rest, &(&1 =~ "@quotable"))
  end

  test "the frames read back as the line they were cut from" do
    line = "Frisch geflasht, unter zwei Sekunden"

    assert "@quotable" |> frames(line) |> Enum.join(" ") == "@quotable: " <> line
  end

  test "no frame is wider than a tab, and words survive whole" do
    line = "Der Kessel steht seit gestern im Keller und heizt das ganze Haus"
    cut = frames("@quotable", line)

    words = Enum.flat_map(cut, &String.split(&1, " "))

    assert Enum.all?(cut, &(String.length(&1) <= 24))
    # What the frames carry is the opening of the line, word for word.
    assert words == Enum.take(String.split("@quotable: " <> line, " "), length(words))
  end

  test "a long post stops at the frame cap rather than paging all evening" do
    # Three, because a hidden tab gives us about four one-second frames before
    # the browser stops advancing the timer and the fourth has to be the line
    # that is still true a minute later.
    long = String.duplicate("Wort ", 200)

    assert length(frames("@quotable", long)) == 3
  end

  test "a word wider than a frame gets one of its own, cut hard" do
    url = "https://example.com/" <> String.duplicate("a", 80)

    # Without the hard cut the URL would be one 100-character frame and the two
    # frames after it would never carry any of the sentence.
    assert [first, second | _] = frames(nil, url <> " danach kommt noch etwas")
    assert String.length(first) <= 24
    assert String.length(second) <= 24
  end

  test "an author with nothing to quote still says who it was" do
    assert frames("@quotable", nil) == ["@quotable"]
  end

  test "nothing to say at all is no teaser" do
    assert frames(nil, nil) == []
    assert PostTeaser.title_frames(nil) == []
  end
end
