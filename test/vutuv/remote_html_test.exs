defmodule Vutuv.RemoteHtmlTest do
  @moduledoc """
  The one place HTML written by a remote server becomes text vutuv will store
  and show — shared by the Mastodon profile feed and the inbound Fediverse
  replies (issue #1069), so it is worth testing on its own rather than only
  through either caller.
  """
  use ExUnit.Case, async: true

  alias Vutuv.RemoteHtml

  test "paragraphs and line breaks survive as line breaks" do
    assert RemoteHtml.to_text("<p>Hallo <b>Welt</b></p><p>Zweiter</p>") == "Hallo Welt\n\nZweiter"
    assert RemoteHtml.to_text("eins<br>zwei<br/>drei") == "eins\nzwei\ndrei"
  end

  test "the base entities are decoded exactly once" do
    assert RemoteHtml.to_text("<p>Tom &amp; Jerry &lt;3</p>") == "Tom & Jerry <3"
    assert RemoteHtml.to_text("<p>&amp;amp;</p>") == "&amp;"
  end

  test "so does the long tail of named entities, and case is not folded" do
    # The six-entry table this replaced is what let `Google&rsquo;s new phone`
    # through verbatim. `:mochiweb_charref` is the full HTML5 table.
    assert RemoteHtml.to_text("<p>Google&rsquo;s new phone</p>") == "Google\u2019s new phone"
    assert RemoteHtml.to_text("<p>&Aacute; und &aacute;</p>") == "\u00C1 und \u00E1"
  end

  test "an entity nobody knows is left standing rather than swallowed" do
    assert RemoteHtml.to_text("<p>&bogus; bleibt</p>") == "&bogus; bleibt"
  end

  test "no NUL byte leaves to_text/3" do
    # Not cosmetic: this text is STORED — `Vutuv.Fediverse`'s `remote_text/3`
    # writes it into a delivered post's body — and Postgres refuses a NUL with
    # `22021 character_not_in_repertoire`, so a federating server could raise
    # our insert with `&#0;` in a Note.
    #
    # The decoder's own guard cannot catch it: `strip_tags/1` decodes numeric
    # entities itself, so the byte exists before the decoder runs. Hence the
    # separate scrub, and hence this test.
    assert RemoteHtml.to_text("<p>hallo &#0; welt</p>") == "hallo  welt"
    refute RemoteHtml.to_text("<p>&#0;</p>") =~ <<0>>
  end

  test "a numeric character reference past the Unicode range does not raise" do
    # The NUL above is the same attack one step further on: `strip_tags/1`
    # decodes numeric references itself, and its parser builds every one it
    # sees. `:mochiutf8.codepoint_to_bytes/1` has no clause past 0x10FFFF, so
    # `&#1114112;` raises a FunctionClauseError from INSIDE `strip_tags/1` —
    # earlier than `scrub_nul/1`, and an exception rather than a failed insert.
    # Any federating server can stop an inbound Note with it.
    #
    # Defused before the parser, so the reference stays literal text, which is
    # what mochiweb already does with a lone surrogate.
    assert RemoteHtml.to_text("<p>a&#1114112;b</p>") == "a&#1114112;b"
    assert RemoteHtml.to_text("<p>a&#x110000;b</p>") == "a&#x110000;b"
    assert RemoteHtml.to_text("<p>a&#99999999;b</p>") == "a&#99999999;b"

    # The boundary itself is a real codepoint and must still decode, or the
    # guard is off by one.
    assert RemoteHtml.to_text("<p>a&#x10FFFF;b</p>") == "a\u{10FFFF}b"

    # Unchanged by the defusing: a surrogate was already left standing, and an
    # ordinary reference must not be caught by it.
    assert RemoteHtml.to_text("<p>a&#xD800;b</p>") == "a&#xD800;b"
    assert RemoteHtml.to_text("<p>a&#8217;b</p>") == "a’b"
  end

  describe "script and style go with their contents" do
    test "a paired element leaves nothing behind" do
      assert RemoteHtml.to_text("<script>alert(1)</script><p>safe</p>") == "safe"
      assert RemoteHtml.to_text("<style>body{color:red}</style><p>safe</p>") == "safe"
    end

    test "the tag may carry attributes and odd casing" do
      assert RemoteHtml.to_text(~s(<SCRIPT type="text/javascript">x=1</SCRIPT>hi)) == "hi"
    end

    test "an unclosed element takes the rest with it" do
      # It runs to the end of the document by definition, so there is nothing
      # after it worth keeping.
      assert RemoteHtml.to_text("<p>before</p><script>alert(1)") == "before"
    end

    test "a member's own text mentioning the word is untouched" do
      assert RemoteHtml.to_text("<p>Ich schreibe ein Script.</p>") == "Ich schreibe ein Script."
    end
  end

  test "everything else is stripped, attributes included" do
    assert RemoteHtml.to_text("<img src=x onerror=alert(2)>danach") == "danach"
    refute RemoteHtml.to_text(~s(<a href="javascript:x">klick</a>)) =~ "javascript:"
  end

  test "the result is clamped to the requested length" do
    long = "<p>" <> String.duplicate("a", 200) <> "</p>"

    assert String.length(RemoteHtml.to_text(long, 50)) == 50
    assert String.ends_with?(RemoteHtml.to_text(long, 50), "…")
  end

  test "anything that is not a string reduces to nothing" do
    assert RemoteHtml.to_text(nil) == ""
    assert RemoteHtml.to_text(42) == ""
  end

  describe "mentions expand to their full fediverse address" do
    # A Mention tag as Mastodon sends one for a same-server account: the name
    # carries only the bare `@user`, the host lives in the href.
    @mention %{
      "type" => "Mention",
      "href" => "https://social.cologne/users/herrkaschke",
      "name" => "@herrkaschke"
    }

    test "a same-server mention takes its host from the tag's href" do
      html =
        ~s(<p>Starker Track von <a href="https://social.cologne/@herrkaschke" class="u-url mention">@<span>herrkaschke</span></a>.</p>)

      assert RemoteHtml.to_text(html, nil, [@mention]) ==
               "Starker Track von @herrkaschke@social.cologne."
    end

    test "a cross-server mention takes its host from the tag's name" do
      tag = %{
        "type" => "Mention",
        "href" => "https://other.example/users/anna",
        "name" => "@anna@other.example"
      }

      assert RemoteHtml.to_text("<p>Hi @anna</p>", nil, [tag]) == "Hi @anna@other.example"
    end

    test "every occurrence expands, case-insensitively, keeping the tag's spelling" do
      assert RemoteHtml.to_text("<p>@HERRKASCHKE und @herrkaschke</p>", nil, [@mention]) ==
               "@herrkaschke@social.cologne und @herrkaschke@social.cologne"
    end

    test "an already fully-qualified handle is not expanded again" do
      assert RemoteHtml.to_text("<p>@herrkaschke@social.cologne</p>", nil, [@mention]) ==
               "@herrkaschke@social.cologne"
    end

    test "an email address and a URL path are never rewritten" do
      html = "<p>Mail an post@herrkaschke.de oder social.cologne/@herrkaschke</p>"

      assert RemoteHtml.to_text(html, nil, [@mention]) ==
               "Mail an post@herrkaschke.de oder social.cologne/@herrkaschke"
    end

    test "a shorter mention never chews up a longer handle beside it" do
      short = %{"type" => "Mention", "href" => "https://a.example/users/herr", "name" => "@herr"}

      assert RemoteHtml.to_text("<p>@herr und @herrkaschke</p>", nil, [short, @mention]) ==
               "@herr@a.example und @herrkaschke@social.cologne"
    end

    test "two mentioned accounts sharing one short name stay plain (ambiguous)" do
      other = %{
        "type" => "Mention",
        "href" => "https://b.example/users/herrkaschke",
        "name" => "@herrkaschke"
      }

      assert RemoteHtml.to_text("<p>@herrkaschke</p>", nil, [@mention, other]) == "@herrkaschke"
    end

    test "a mention of an account on this very installation is expanded too" do
      # It used to be left short, because the renderer sent the full form back
      # at this server as `https://host/@user`, a path vutuv does not serve.
      # It resolves that address to the member's profile now (issue #1560), so
      # a remote post naming one of us links to them. `www.` is us (#1211).
      local = %{
        "type" => "Mention",
        "href" => "https://www.localhost/users/stefan",
        "name" => "@stefan@www.localhost"
      }

      assert RemoteHtml.to_text("<p>@stefan</p>", nil, [local]) == "@stefan@www.localhost"
    end

    test "a name the renderer could not link is not expanded" do
      dotted = %{
        "type" => "Mention",
        "href" => "https://misskey.example/@who.else",
        "name" => "@who.else"
      }

      assert RemoteHtml.to_text("<p>@who.else</p>", nil, [dotted]) == "@who.else"
    end

    test "a single tag map (not wrapped in a list) works" do
      assert RemoteHtml.to_text("<p>@herrkaschke</p>", nil, @mention) ==
               "@herrkaschke@social.cologne"
    end

    test "hashtag tags and malformed mention tags are ignored" do
      tags = [
        %{"type" => "Hashtag", "name" => "#musik", "href" => "https://social.cologne/tags/musik"},
        %{"type" => "Mention", "name" => "@x"},
        %{"type" => "Mention", "href" => "https://social.cologne/users/x"},
        "not a map"
      ]

      assert RemoteHtml.to_text("<p>@musik @x</p>", nil, tags) == "@musik @x"
    end

    test "the clamp still bounds the expanded text" do
      out = RemoteHtml.to_text("<p>@herrkaschke</p>", 10, [@mention])

      assert String.length(out) == 10
      assert String.ends_with?(out, "…")
    end
  end

  describe "a custom-emoji shortcode is taken out of the text" do
    test "an inline one goes, and the gap it leaves closes" do
      html = ~s(<p>Linux im Park mit den Piraten :tux: :piraten:</p>)

      assert RemoteHtml.to_text(html) == "Linux im Park mit den Piraten"
    end

    test "one used as a bullet at the start of a line goes with its space" do
      html =
        "<p>:picklerick: Füg nicht die KI ein.</p><p>:cannabis: Wenn dir jemand schreibt.</p>"

      assert RemoteHtml.to_text(html) ==
               "Füg nicht die KI ein.\n\nWenn dir jemand schreibt."
    end

    test "a line that was nothing but one does not leave a blank line behind" do
      html = "<p>Wir suchen jemanden.<br>:BoostOK:<br>Danke!</p>"

      assert RemoteHtml.to_text(html) == "Wir suchen jemanden.\nDanke!"
    end

    test "the gap never turns into a stray space before punctuation" do
      html = "<p>Hey Wesen des Fediversums :fediverse: , bis Sonntag.</p>"

      assert RemoteHtml.to_text(html) == "Hey Wesen des Fediversums, bis Sonntag."
    end

    test "a post that was nothing but one reduces to nothing" do
      assert RemoteHtml.to_text("<p>:blobcatcool:</p>") == ""
    end

    test "Unicode emoji are not shortcodes and stay exactly where they are" do
      assert RemoteHtml.to_text("<p>Ever wanted to have fun? \u{1F911} Yes!</p>") ==
               "Ever wanted to have fun? \u{1F911} Yes!"
    end

    test "two adjacent ones go together, the way those servers write them" do
      assert RemoteHtml.to_text("<p>Cem :blobcat::verified: hier</p>") == "Cem hier"
    end

    test "a time, a URL and a scope operator are left alone" do
      assert RemoteHtml.to_text("<p>Um 10:30:45 Uhr</p>") == "Um 10:30:45 Uhr"
      assert RemoteHtml.to_text("<p>https://example.org/a</p>") == "https://example.org/a"
      # A colon is not a delimiter, or this would read as a `:vector:` emoji
      # between two colons and come out `std::size`.
      assert RemoteHtml.to_text("<p>std::vector::size</p>") == "std::vector::size"
    end

    test "text carrying no shortcode comes out byte for byte as before" do
      html = "<p>Zeile  eins</p><p>  Zeile zwei  </p>"

      assert RemoteHtml.to_text(html) == "Zeile  eins\n\n  Zeile zwei"
    end

    test "the strip runs before the clamp, so the cap bounds real text" do
      html = "<p>:tux: " <> String.duplicate("a", 40) <> "</p>"

      assert RemoteHtml.to_text(html, 20) == String.duplicate("a", 19) <> "\u{2026}"
    end
  end
end
