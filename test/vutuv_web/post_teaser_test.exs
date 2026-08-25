defmodule VutuvWeb.PostTeaserTest do
  @moduledoc """
  Which line teases a post, and how a quote is cut into browser-tab frames
  (issues #1668 and #1681).

  The frames are the whole feature on that surface: a hidden tab gives us about
  four of them before the browser stops advancing the timer, and each one has
  to be a line somebody can read in the width of a tab. So what is worth
  pinning is that the author leads, that words are not cut in half, that a
  pasted URL cannot swallow the frames after it, and that the cap holds.

  The `line/2` half below pins the other decision: which line of a post is
  worth showing at all. Nine surfaces read it, so an exception added here is
  one every one of them gets, and the two shapes must never name different
  lines of one post.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts.Post
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

  @quoted "RE: https://mastodon.social/@AwetTesfaiesus/117158047146805008"

  describe "line/2" do
    test "is the first line of the body" do
      post = %Post{body: "Funfact: ein Teil meines Wahlkreises\n\nliegt in Thüringen"}

      assert PostTeaser.line(post) == "Funfact: ein Teil meines Wahlkreises"
    end

    test "skips the blank and whitespace-only lines a body opens with" do
      assert PostTeaser.line(%Post{body: "\n   \nEndlich\n"}) == "Endlich"
    end

    test "caps at 200 characters, and at :length when one is given" do
      post = %Post{body: String.duplicate("a", 300)}

      assert String.length(PostTeaser.line(post)) == 200
      assert String.length(PostTeaser.line(post, length: 30)) == 30
    end

    test "a post without a body has no teaser" do
      assert PostTeaser.line(%Post{body: nil}) == ""
      assert PostTeaser.line(%RemotePost{content_text: nil}) == ""
    end

    test "skips a line with no words in it" do
      assert PostTeaser.line(%Post{body: "---\n\nDer Rest"}) == "Der Rest"
      assert PostTeaser.line(%Post{body: "```elixir\nIO.puts(1)"}) == "IO.puts(1)"
      assert PostTeaser.line(%Post{body: "![](a.jpg) ![](b.jpg)\n\nDer Rest"}) == "Der Rest"
    end

    test "skips a line that is nothing but hashtags" do
      post = %Post{body: "#Solarpunk #klimakrise #noafd\n\nDas Dach ist fertig."}

      assert PostTeaser.line(post) == "Das Dach ist fertig."
    end

    test "keeps a line where the hashtags are part of a sentence" do
      post = %Post{body: "Endlich Strom vom Dach #Solarpunk\n\nMehr dazu"}

      assert PostTeaser.line(post) == "Endlich Strom vom Dach #Solarpunk"
    end

    test "does not mistake a Markdown heading for hashtags" do
      assert PostTeaser.line(%Post{body: "# Titel\n\nDer Rest"}) == "# Titel"
      assert PostTeaser.line(%Post{body: "## Zwischentitel\n\nDer Rest"}) == "## Zwischentitel"
    end

    test "keeps a hashtag line this module's narrower grammar does not cover" do
      # Not because `Vutuv.Mentions` cannot read `#Grüne` — it can, its token
      # spans Unicode letters (\p{L}), which is what makes `#Thüringen` name its
      # own tag rather than `#Th`. This module's `@hashtags_only` is deliberately
      # narrower: it decides what to **drop**, and dropping a line the reader
      # wanted is the expensive mistake, so anything it cannot prove is a pure
      # hashtag line stays.
      #
      # The cost is that on a German site the "a hashtag line does not tease"
      # rule (v7.360.2) stops firing as soon as one tag carries an umlaut. That
      # is a product call, not an oversight.
      post = %Post{body: "#Grüne #Klima\n\nDer Rest"}

      assert PostTeaser.line(post) == "#Grüne #Klima"

      # The same line in ASCII is skipped, which is that rule working.
      assert PostTeaser.line(%Post{body: "#Gruene #Klima\n\nDer Rest"}) == "Der Rest"
    end

    test "reads a remote post and a remote reply off their own text column" do
      assert PostTeaser.line(%RemotePost{content_text: "Von drüben"}) == "Von drüben"
      assert PostTeaser.line(%Note{content_text: "Geantwortet"}) == "Geantwortet"
    end
  end

  describe "line/2 skips a quote-post reference" do
    test "and shows the first line the author actually wrote" do
      post = %RemotePost{content_text: @quoted <> "\n\nFunfact: ein Teil meines Wahlkreises"}

      assert PostTeaser.line(post) == "Funfact: ein Teil meines Wahlkreises"
    end

    test "in a member's own body too" do
      assert PostTeaser.line(%Post{body: @quoted <> "\n\nDazu fällt mir ein"}) ==
               "Dazu fällt mir ein"
    end

    test "in angle brackets, and however the server cased it" do
      post = %RemotePost{content_text: "re: <https://mastodon.social/@a/1>\n\nDanach"}

      assert PostTeaser.line(post) == "Danach"
    end

    test "but keeps a RE: line that is prose rather than a bare URL" do
      post = %RemotePost{content_text: "RE: what Daniel said\n\nDanach"}

      assert PostTeaser.line(post) == "RE: what Daniel said"
    end

    test "but keeps it when it is all the post has: a URL beats an empty teaser" do
      assert PostTeaser.line(%RemotePost{content_text: @quoted}) == @quoted
    end

    test "and where only hashtags follow it, they are the teaser rather than the URL" do
      # A real shape in the data: a quote post whose whole body is the
      # reference and a row of filing. Hashtags are words, a status URL is not.
      post = %RemotePost{content_text: @quoted <> "\n\n#Solarpunk #klimakrise #noafd"}

      assert PostTeaser.line(post) == "#Solarpunk #klimakrise #noafd"
    end

    test "only where the post opens with it, never mid-body" do
      post = %RemotePost{content_text: "Schau mal\n\n" <> @quoted}

      assert PostTeaser.line(post) == "Schau mal"
    end
  end

  describe "plain_line/2" do
    test "flattens the Markdown markers of a member's body" do
      post = %Post{body: "# Eine **fette** Überschrift\n\nDer Rest"}

      assert PostTeaser.plain_line(post) == "Eine fette Überschrift"
    end

    test "leaves a remote post's plain text alone, whitespace folded" do
      post = %RemotePost{content_text: "Zwei   Wörter"}

      assert PostTeaser.plain_line(post) == "Zwei Wörter"
    end

    test "skips the quote reference like line/2 does" do
      post = %RemotePost{content_text: @quoted <> "\n\nFunfact: ein Teil"}

      assert PostTeaser.plain_line(post) == "Funfact: ein Teil"
    end

    test "names the same line line/2 does, so no two surfaces quote a post differently" do
      post = %Post{body: "---\n\n# **Der** Rest"}

      assert PostTeaser.line(post) == "# **Der** Rest"
      assert PostTeaser.plain_line(post) == "Der Rest"
    end
  end
end
